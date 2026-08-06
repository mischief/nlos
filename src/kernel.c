/* cooperative mach-lite kernel: lua_State procs, ports, rights.
 *
 * - each proc = own lua_State (heap isolation) + one lua thread the
 *   chunk runs on
 * - ports = kernel-side fifo of serialized messages
 * - rights = small-int handles in a per-proc table; lua never sees
 *   pointers. handle 0 is always the proc's own receive port.
 * - blocking recv/readline is lua-side sugar over tryrecv + block
 * - preemption via count hook: busy loops can't starve the machine
 * - keyboard: kernel pumps ConIn into a port whose receive right is
 *   given to proc 0
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "efi.h"
#include <sys/queue.h>

#include "kernel.h"
#include "cpu.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luaheap.h"
#include "debug.h"
#include "platform.h"

/* MAXPROCS and MAXPORTS come from the platform's param.h, because what
 * is headroom on a machine with gigabytes is a third of a board's ram.
 *
 * bodies are heap-allocated, so what these cost statically is one
 * pointer each -- but that is per entry, in .bss, whether or not a proc
 * ever exists. on a 32-bit target 4096 procs and 32768 ports is 144KB,
 * measured against the esp32's 242KB of internal sram at heap_init.
 *
 * they are headroom rather than reachable counts: spawning until it
 * fails stops at about 960 procs on efi, because each is a lua_State
 * and the heap runs out long before the tables do. dispatch and wakeups
 * do not scan, so the round trip is flat across the whole range (about
 * 26k cycles at 64 procs and at 8192) -- which is exactly why a small
 * platform can pick a small number and lose nothing but headroom.
 *
 * going further wants a two-level index rather than a flat one, which
 * would add an indirection to every serialize.
 *
 * MAXRIGHTS is what bounds a supervisor: sys.spawn hands the parent a
 * right per child, so holding them caps the tree at MAXRIGHTS unless the
 * parent closes each handle and tracks children by pid through
 * sys.monitor. only the first NRIGHTS_INLINE cost anything per proc.
 */
#include "param.h"

#ifndef MAXPROCS
#error "platform param.h must define MAXPROCS"
#endif
#ifndef MAXPORTS
#error "platform param.h must define MAXPORTS"
#endif

#define MAXRIGHTS	512
#define NRIGHTS_INLINE	8

/* the serializer puts a port's index in a 16-bit field (the 'R' case), so
 * a port beyond that would alias onto a live one and the receive side's
 * range check could not catch it -- the aliased value is in range. fail
 * the build rather than corrupt delivery.
 */
_Static_assert(MAXPORTS <= 65536, "port index is 16 bits in the serializer");
/* fallback if calibration fails; normally replaced at boot by a measured
 * value -- see calibrate_reductions().
 */
#define REDUCTIONS	25000
#define MAXMSG		(64 * 1024)
#define MAXDEPTH	16
#define MAXMSGRIGHTS	8	/* rights per message */
#define MAXWATCH	8	/* monitors per proc */
#define MAXWEIGHT	16	/* sys.set_priority clamp -- see kernel_run's WRR loop */
#define MAXTIMERS	32	/* outstanding one-shot timers, machine-wide */
/* floor on phase two's dispatch bound -- see kernel_run.
 *
 * the bound is what ends a lap at all, because a mid-lap wakeup joins
 * the current runq and two procs feeding each other hand phase two a
 * fresh proc every time it takes one. sized to amortise rather than
 * merely to terminate: everything between laps costs a fixed toll, one
 * port-i/o trap on microvm and three firmware calls on efi, and a bound
 * of "whatever was queued" charges a ping-pong pair the whole toll per
 * exchange -- measured at 3.8x on a bare cross-proc round trip. what it
 * costs in return is the delay a busy pair can impose on a timer, which
 * is this many round trips, ~0.1ms. the tick is 10ms.
 */
#define LAPSPILL	64
/* per-port queue ceiling. plan 9's pipes are Queues with a limit
 * (conf.pipeqsize, 256KB) and a writer that sleeps when it is reached;
 * ours had no bound at all, so a fast writer into a slow reader grew the
 * kernel heap without limit -- and that memory is charged to no proc's
 * mem_limit, so it did not even show up in the containment story.
 *
 * this is the interim: over the limit, the send FAILS rather than
 * blocking. that closes the memory hole without inventing send-side
 * blocking, which needs a new blocked-on-write proc state and a wakeup
 * when the queue drains. a writer outrunning its reader gets an error,
 * which is at least a real signal rather than silent growth.
 */
#define MAXQUEUE	(64 * 1024)
/* fair-share averaging window. plan 9 uses schedgain=30 SECONDS, which
 * suits long-lived unix-ish processes; ours are short and interactive.
 *
 * the mixing weight below is n/D, which approximates a true exponential
 * only while n is small next to D. that holds now that the scheduler
 * samples every lap (n is ~15ms), but it is why the metric used to
 * depend on how often anyone asked for it: one on-demand call with
 * n=1500 mixed at 0.75 where the real figure is 1-exp(-0.75)=0.53, and
 * read a spinning proc at 729 instead of the ~950 it deserved.
 *
 * 500ms converges in roughly 1.5s, which suits procs that live for
 * seconds. it must stay well above the lap period for the linear
 * approximation to hold.
 */
#define SCHED_DECAY_MS	500
/* wall-clock slice a proc may hold before the count hook yields it. the
 * hook fires on instruction count; this converts that into a time bound.
 * well under the ~10ms timer floor, so it never becomes the thing that
 * delays a tick.
 */
#define QUANTUM_MS	2
/* priority resolution per unit of weight. plan 9's PriNormal is 10 and
 * its bands run 0..19; weight is our basepri, so this is what gives a
 * default-weight proc a 0..10 range to move in rather than 0..1.
 */
#define PRI_BASE	10

/* BROKE is plan 9's: a proc that died of an error and is being held so
 * something can look at it. it is not runnable and holds no rights, but
 * its lua_State is still standing, which is the whole point -- a
 * coroutine that errors out of lua_resume does not unwind, so at the
 * moment of death every frame is still there. today that stack lives
 * exactly long enough for luaL_traceback to flatten it into one string
 * and is then closed, which throws away everything except the summary
 * right when the summary stops being enough.
 *
 * sys.stack already reads a suspended proc's state without disturbing
 * it (see src/debug.c). a corpse is a proc suspended forever, so the
 * rules that file keeps -- run nothing, allocate nothing, restore the
 * top -- hold on it unchanged. holding the state costs nothing but the
 * heap it sits in, so the number of corpses is capped.
 */
enum { DEAD, READY, BLOCKED, BROKE };
/* PRIV_BOOT is proc 0 and nothing else. it is not a device capability
 * like the rest -- it means "this proc is where the raw ESP reaches",
 * which is true only of the proc the kernel starts itself, and is what
 * lets it build the root namespace every other proc inherits.
 */
enum { PRIV_NONE, PRIV_BOOT, PRIV_ESP, PRIV_CONS, PRIV_WIRE, PRIV_POWER,
    PRIV_P9, PRIV_ETH, PRIV_FB, PRIV_BLK, PRIV_FLASH };

/* line trace: the last N lines a proc executed, in a ring.
 *
 * sys.stack answers "where is this proc now", which is the wrong
 * question after a fault -- by then the interesting part is how it got
 * there, and a stack shows the calls that are still open, not the ones
 * that returned. this is the other half, and it is only worth having
 * because a broke proc survives long enough to be read.
 *
 * cost is the reason it is off by default. a line hook fires per line
 * rather than per REDUCTIONS instructions, so the fixed cost per entry
 * decides what a traced proc runs like. hence: the line number arrives
 * free (lua fills ar->currentline before calling the hook for a line
 * event, so no lua_getinfo is needed for it), and the source name is
 * interned by pointer, which hits on every line of a run inside one
 * function -- that is nearly all of them.
 *
 * the ring is C memory, deliberately: charging it to the proc's
 * mem_limit would mean the act of debugging a proc near its cap could
 * push it over, the same reason src/debug.c allocates nothing in a
 * target it is reading.
 */
/* los.sys entries, which is what per-proc call counting is sized by.
 * Checked against the real table at registration -- see los_sys_open.
 */
#define NSYSCALL	64

#define TRACESRC	32	/* distinct source files remembered */
#define TRACECO		16	/* coroutines distinguished, as in debug.c */
#define TRACEMAX	4096	/* entries, per proc */

struct tracent {
	int line;
	unsigned short src;	/* index into ktrace.name */
	unsigned short co;	/* index into ktrace.co */

	/* Two clocks, from one tsc read, each as a delta from the previous
	 * entry rather than an absolute.
	 *
	 * `cpu` is cycles this proc actually spent running, so deltas are
	 * disjoint across procs and a line's own cost is what it says.
	 * `wall` is elapsed cycles, so `wall - cpu` is how long the proc
	 * was NOT running after that line -- the kernel, another proc, or
	 * idle. Neither alone is enough: per-proc cycles are blind to
	 * everything outside the proc, and wall alone cannot be summed
	 * across procs, since two timelines covering one interval would
	 * count it twice.
	 *
	 * u32 because consecutive lines are microseconds apart at most. An
	 * absolute u32 would wrap in under a second at 4.5GHz; a delta
	 * does not, and saturates rather than wrapping if a proc really
	 * was away for longer.
	 */
	unsigned int wall;
	unsigned int cpu;
};

struct ktrace {
	struct tracent *ent;
	unsigned int cap;	/* entries */
	unsigned int n;		/* entries written, ever */
	char name[TRACESRC][LUA_IDSIZE];
	int nname;
	/* the fast path: consecutive lines almost always come from the
	 * same function, so a one-entry cache on the source pointer
	 * turns interning into a compare. the pointer is only ever
	 * compared, never dereferenced, because the string it names
	 * belongs to the target and may be collected.
	 */
	const void *lastsrc;
	int lastid;
	unsigned long long lastwall;	/* tsc at the previous entry */
	unsigned long long lastcpu;	/* running cycles at the previous entry */
	const void *co[TRACECO];
	int nco;
};

struct kmsg {
	struct kmsg *next;
	size_t len;
	/* ports referenced by in-flight rights in this message. they hold
	 * a ref each so a port can't be freed (and its index reused) while
	 * the only right to it sits in a queue.
	 */
	unsigned short refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];	/* was each one a recv right? */
	int nrefs;
	unsigned char *data;	/* owned; freed by msg_free */
};

struct kport {
	unsigned short idx;	/* its slot in portv; what the wire carries */
	int used;
	TAILQ_HEAD(, waiter) waiters;
	/* rights + in-flight message refs + kernel refs, and the receive
	 * rights among those.
	 *
	 * Atomic because they are the one part of a port touched with no
	 * bucket held. serialize walks a message minting a reference on
	 * every port it names -- arbitrary ports, so arbitrary buckets --
	 * and it has to run outside the lock entirely, because building
	 * the message allocates lua memory and the collector reaches
	 * api_close from there.
	 *
	 * Taking a reference is safe unlocked because it cannot destroy
	 * anything: whoever increments already holds one, so the count
	 * was not zero and cannot reach zero underneath. Dropping one
	 * can, so port_unref still runs under every bucket, and that is
	 * what serializes a drop against the flush it may perform.
	 */
	atomic_int nrights;
	atomic_int nrecv;
	int dead;	/* no receive right left; sends are dropped */
	size_t qbytes;	/* queued payload, against MAXQUEUE */
	struct kmsg *head, *tail;

	/* counters, for sys.ports(). The kernel is where a send is refused,
	 * so it is the only place that can count refusals for every port
	 * rather than for the one task that thought to keep its own tally.
	 *
	 * full and dead are separate because they are different faults: a
	 * full queue is a reader that fell behind, a dead one is a receive
	 * right closed while someone was still sending to it.
	 *
	 * qpeak rather than only qbytes because a queue is almost never
	 * sampled at its worst moment. One that touched MAXQUEUE and
	 * drained reads as idle, which is exactly the port worth knowing
	 * about.
	 */
	unsigned long long nsent;
	unsigned long long ndrop_full;
	unsigned long long ndrop_dead;
	size_t qpeak;
};

struct right {
	struct kport *port;
	int recv;
	int used;
};

/* what the kernel granted a proc at spawn, by NAME. handle numbers are
 * whatever right_new's first-free search picked and are not an abi --
 * lua reads this mapping through sys.granted() instead of hardcoding a
 * constant. a capability that doesn't exist this boot is simply an
 * absent key, which is both cheaper and safer than probing with a send
 * (a successful send transfers the right for real, so a probe that
 * "just checks" hands the capability to whoever it was aimed at).
 */
struct grant {
	const char *name;
	int handle;
	SLIST_ENTRY(grant) e;	/* on proc->grants; walked whole */
};

/* a proc waiting on a port. one record per (proc, port) pair, because a
 * proc in an alt waits on several at once -- so the port's list and the
 * proc's list both need their own linkage.
 *
 * the pool is fixed and shared: the cost is proportional to how many
 * waits are outstanding, not to MAXPROCS, which is the difference that
 * matters. an inline array per proc would cost one slot per port a
 * proc could possibly wait on, times MAXPROCS,
 * whether anything is blocked or not.
 */
struct kproc;

struct waiter {
	struct kproc *p;
	struct kport *port;
	int send;			/* waiting for room, not for a message */
	/* still linked on port->waiters. A waker unlinks the entry it
	 * woke on and clears this, under that port's bucket; the entries
	 * the proc holds on OTHER ports stay linked, and collecting them
	 * is the proc's own job. See wait_reap.
	 */
	int onport;
	TAILQ_ENTRY(waiter) pq;		/* on port->waiters */
	SLIST_ENTRY(waiter) pw;		/* on proc->waiters; walked whole */
};

struct kproc {
	int status;
	int id;			/* unique forever; slots are reused, ids not */
	lua_State *L;		/* owning state */
	lua_State *co;		/* thread the chunk runs on */
	SLIST_HEAD(, waiter) waiters;	/* ports this proc is blocked on */
	/* almost every block waits on exactly one port, so the first record
	 * is inline and costs no allocation on what is the hot path for
	 * IPC. an alt over several ports takes the rest from the heap.
	 */
	struct waiter w0;
	int w0used;
	TAILQ_ENTRY(kproc) rqe;		/* on one of the dispatch sets */
	struct rqset *onq;		/* which, or null */
	/* blocked waiting for ROOM on this port, the send-side mirror of
	 * `waiting`. separate field rather than a flag on `waiting` so
	 * wake_receivers and wake_senders cannot wake each other's procs:
	 * a reader waiting for data and a writer waiting for space are
	 * woken by opposite events on the same port.
	 */
	/* handles index this: the first NRIGHTS_INLINE live in the proc, the
	 * rest in an array allocated only if a proc ever needs one. most
	 * hold a handful -- a driver task two, an ordinary proc one to three
	 * -- while a shell running a pipeline reaches thirty, so the inline
	 * part covers the numerous case and the busy case pays for itself.
	 * sys.stats().rightshigh reports the high water if this needs
	 * revisiting.
	 */
	struct right rights[NRIGHTS_INLINE];
	struct right *xrights;		/* MAXRIGHTS - NRIGHTS_INLINE, or null */
	int rhint;			/* lowest slot that might be free */
	int rhigh;			/* one past the highest slot ever used */
	TAILQ_HEAD(, kextra) coros;	/* every lua_State of this proc */
	int hookforced;			/* 0 none, 1 p->co armed, 2 all armed */
	int torture;			/* yield between EVERY instruction */

	/* held still so another proc can read it. Nonzero means dispatch
	 * must not resume this proc: it is counted rather than a flag
	 * because two readers may look at one target at once, and the
	 * second must not thaw it under the first.
	 *
	 * Guarded by schedlock, like `current` -- freezing is deciding
	 * something about the run queues, and is done holding the same
	 * lock that publishes who is running.
	 */
	int frozen;

	/* some port has claimed the right to wake this proc.
	 *
	 * A proc in an alt waits on several ports at once, so several
	 * cpus can decide to wake it at the same moment, each holding a
	 * different bucket and neither covering the other. This is what
	 * settles it: the winner is whoever takes the flag from 0 to 1,
	 * and a loser leaves the proc alone entirely. Go's runtime does
	 * exactly this with g.selectDone, for exactly this reason.
	 *
	 * Cleared by wait_reap, which runs on the proc's own cpu before
	 * it is resumed -- so it is 0 for the whole time the proc is
	 * running, and there is nothing to claim until it blocks again.
	 */
	atomic_int woken;

	/* which cpu has this proc in hand, plus one, or zero for none.
	 *
	 * One proc is one thread of control, and every invariant in this
	 * kernel rests on it: a per-proc lua heap needs no lock, a virtio
	 * queue needs no lock, and a coroutine cannot be resumed twice.
	 * Two cpus dispatching one proc breaks all three at once, and it
	 * does not report itself -- it arrives later as a page fault on a
	 * pointer that was fine, or as lua refusing to resume.
	 *
	 * So it is checked rather than argued. Written under schedlock at
	 * both ends, which is where a proc is taken and given back.
	 */
	unsigned oncpu;

	int watchers[MAXWATCH];	/* pids to notify when this proc dies */
	int nwatch;
	struct luaheap *heap;	/* this proc's lua heap; see kalloc */
	/* which cpu dispatches this proc. Not p->cpu, which is taken and
	 * means a percentage. A proc's queues live on its home cpu, so
	 * this is what make_ready enqueues against -- from whichever cpu
	 * happens to be sending, which is the only cross-cpu operation
	 * the scheduler has.
	 */
	unsigned home;
	int reductions;		/* instruction budget per slice */
	/* args waiting on co's stack for the FIRST resume only: sys.spawn's
	 * `arg`, already deserialized into this proc, which the chunk
	 * receives as `...`. zeroed after that resume so the weight loop's
	 * later resumes pass nothing.
	 */
	int nargs;
	size_t mem_used;	/* live bytes in this proc's lua heap */
	size_t mem_peak;
	size_t mem_limit;	/* 0 = unlimited */
	char name[32];		/* from chunkname, for ps/debugging */
	/* scheduling feedback. cputime/reds are raw accumulators; cpu is
	 * the decaying fair-share estimate derived from them.
	 */
	unsigned long long cputime;	/* tsc cycles actually spent running */
	unsigned long long lastupdate;	/* uptime_ms at the last updatecpu */
	unsigned long long lastcpu;	/* cputime as of that update */
	unsigned cpu;			/* per-mille of wall time, decayed */
	int pri;			/* computed at ready time, see make_ready */
	unsigned long long resumed;	/* tsc at the current resume, for the hook */
	/* how many times this proc has been given the cpu. cputime says how
	 * long it ran, this says how often it was picked up -- and the two
	 * answer different questions: the same milliseconds spread over
	 * thousands of resumes is a proc round-tripping on ipc, over a
	 * handful is one doing its work in a block.
	 */
	unsigned long long nresume;
	/* named capabilities the kernel handed this proc, read by name
	 * through sys.granted(). a list, not a fixed array: the boot payload
	 * holds one per driver plus disk and sched -- a dozen-odd -- while
	 * every other proc holds none, so an array sized for the former wasted
	 * a quarter of this struct on the latter and, worse, silently dropped
	 * grants once the driver set outgrew it (the dhcpd-missing bug).
	 * appended at spawn, walked whole by sys.granted, freed at
	 * proc_detach; never indexed, so a list costs nothing here.
	 */
	SLIST_HEAD(, grant) grants;
	struct ktrace *trace;	/* line trace ring, or 0; see sys.set_trace */

	/* how many times this proc has made each los.sys call, indexed by
	 * position in kapi[]. See counted() for why it is a wrapper rather
	 * than an increment in each api_ function, and sys.syscalls to read
	 * it.
	 *
	 * Always on, unlike the trace ring, because it is affordable enough
	 * to be: 38 counters is 152 bytes beside a whole lua_State, and
	 * procv holds pointers so it is per live proc rather than per
	 * MAXPROCS. Arming would defeat the point -- the case this exists
	 * for was a task making two syscalls per message, which is only
	 * obvious if it is already being counted when someone first looks.
	 */
	unsigned int calls[NSYSCALL];
	unsigned int brokeseq;	/* death order, so the cap reaps the oldest */
	int exitcode;		/* sys.setexit(); reported by notify_exit */
	char exitmsg[64];	/* plan 9 style exits("why"); "" if unused */
	int weight;		/* WRR share, 1..MAXWEIGHT, see sys.set_priority */
	int priv;		/* PRIV_*; only PRIV_BOOT keeps raw file access */
};

/* procs live on the heap too. a dead one keeps its slot until the reaper
 * runs at the top of a lap, because dispatch reads its status right after
 * a resume that may have killed it -- freeing inside proc_kill would hand
 * dispatch a dangling pointer.
 */
static struct kproc *procv[MAXPROCS];
static int prochigh;
/* ports live on the heap; this is the index that names them. the wire
 * carries the index, not a pointer, so a message stays the same size and
 * a port's identity survives being moved -- and .bss no longer holds a
 * body for every port that could ever exist.
 */
/* the lock over everything shared between procs: the port and proc
 * index tables, every port's message list and waiter list, the
 * refcounts that decide when a port dies, and the rights a sender
 * mints into a receiving proc's table.
 *
 * One lock, not one per port. Per-port is the obvious next refinement
 * and is speculative until something measures contention here: a
 * proc's own heap needs no lock (see kalloc), its lua execution needs
 * none, and its run queues belong to its cpu, so this is taken on the
 * ipc path only. lock.h's order already anticipates the split.
 *
 * The discipline is caller-holds, because the helpers nest --
 * port_push_owned calls wake_receivers calls wait_clear and
 * make_ready -- so a lock taken inside each would deadlock on itself.
 * It is acquired at the outer entry points instead.
 *
 * Two things make "outer" not simply mean "the syscall boundary":
 *
 * the five calls that block (api_block, api_sendblock, api_altblock,
 * api_altrecv, call_k) lua_yield in the middle, and a lock held across
 * a yield is held until that proc is next resumed; and any lua C
 * function may raise, which longjmps out past whatever would have
 * released. So on the lua-facing paths the lock has to go around a
 * region that neither yields nor raises, which is narrower than the
 * function.
 *
 * It is not one lock but an array of them, hashed on the port index.
 * The bucket array is the middle ground between one lock and a lock
 * per port, and it is the cheap way to find out which of those the
 * workload actually wants: buckets are static, so they raise none of
 * the questions a per-port lock does -- what its lifetime is against
 * the port's, and how it orders against the refcount that decides that
 * lifetime. Linux hashes futexes onto a fixed bucket array for the
 * same reason.
 *
 * Eight of them. The number is small on purpose: it costs an acquire
 * per bucket on the paths that need all of them, and the question it
 * has to answer -- does spreading the ports over separate cachelines
 * recover the scaling microvm_pairs loses -- is answered as well by
 * eight as by eighty.
 *
 * Two ways in, and which one a caller uses is the whole of the split:
 *
 *	ipclock_enter()		every bucket, ascending
 *	ipclock_enter_port(p)	the one bucket covering p
 *
 * Taking all of them is what every caller does until measurement moves
 * it, because it is what the single lock did. A caller narrowed to one
 * bucket takes on two obligations that the wide form carries for it:
 * it must touch no port outside that bucket, and it must allocate no
 * lua memory, because the collector reaches api_close and a handle in
 * another bucket -- which is the re-entry the depth counter below
 * absorbs today, and which no lock order can absorb once the two
 * buckets are chosen by a hash.
 */
#define NIPCLOCK 8

struct ipcbucket {
	struct lock lk;
	/* atomic because it is read by a cpu that does not hold the
	 * lock -- that is the whole of ipclock_enter_one's fast path --
	 * while another cpu writes it. Relaxed is enough: the only
	 * value any cpu acts on is its own struct cpu, and a cpu is the
	 * only writer of that value, so a read that races can be stale
	 * but can never be wrongly equal to me.
	 *
	 * depth needs none of that. It is touched only by the owner,
	 * and by definition there is exactly one.
	 */
	_Atomic(struct cpu *) owner;
	int depth;

	/* how long it is held, summed. lock.h counts the waiting; this
	 * counts the other half, and the two together say whether
	 * splitting further would buy anything -- a lock nobody holds
	 * for long is not the thing to split.
	 *
	 * Owner-only, like depth, so no atomics. One rdtsc pair per
	 * outermost acquire is about 1% of one, which is worth paying
	 * for the one number the design question turns on.
	 */
	unsigned long long held, t0;
};

/* zero is the initial state of every field, LOCK_INIT included, so
 * there is nothing to write here.
 */
static struct ipcbucket ipcbuckets[NIPCLOCK];

/* which bucket covers a port. The index is dense from zero and ports
 * are handed out in order, so the low bits spread as well as any
 * mixing would and cost nothing.
 */
static struct ipcbucket *
ipcbucket_of(const struct kport *p)
{
	return &ipcbuckets[p->idx & (NIPCLOCK - 1)];
}

/* the ipc lock is recursive, and it is not a shortcut.
 *
 * Measured, by making re-entry abort and naming both ends:
 *
 *	PANIC: ipclock re-entered: api_close inside api_tryrecv
 *
 * api_tryrecv holds the lock across port_pop_to_lua, which
 * deserializes the message, which allocates, which can run the
 * collector, and a __gc handler here is arbitrary lua -- clunking a
 * handle is the whole reason those handlers exist, so it comes back
 * through api_close. Six tests hung on exactly this and nothing else.
 *
 * There is no "acquire around the shared work only" that avoids it,
 * because the shared work IS the allocation: a message cannot be
 * delivered to lua without building lua objects. The alternatives are
 * stopping the collector across every ipc call, or forbidding
 * finalizers from touching handles, and both are worse than a depth
 * counter.
 *
 * The usual objection to a recursive lock is that it hides a contract
 * bug rather than reporting it. That holds, and the answer here is
 * that this re-entry is neither a bug nor avoidable.
 *
 * The pitfall, because it passes the whole suite: a bucket whose
 * owner is set but whose leave is missed is never released, and every
 * later acquire on that cpu takes the depth fast path and succeeds.
 * The kernel then runs unlocked and green. Anything that changes these
 * two functions wants the assertions in kernel_run -- no bucket held
 * across a lap -- to be the thing that is trusted, not the tests.
 */
/* does this cpu hold this bucket. Not lock.h's holding(), which
 * answers for the machine: under smp another cpu holding a bucket is
 * the ordinary case and says nothing about whether this one may touch
 * the ports under it.
 */
static int
ipcheld_one(struct ipcbucket *b)
{
	return atomic_load_explicit(&b->owner, memory_order_relaxed) ==
	    cpu_self();
}

/* does this cpu hold every bucket, which is what the wide form gives
 * and what an assertion naming no port has to demand.
 */
static int
ipcheld(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		if (!ipcheld_one(&ipcbuckets[i]))
			return 0;
	return 1;
}

/* any bucket at all. The weakest of the three, for a helper whose
 * requirement is that its caller reached it from inside an ipc region
 * rather than that any particular port is covered -- proc_block, which
 * records a decision some port's bucket was holding still.
 */
static int
ipcheld_any(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		if (ipcheld_one(&ipcbuckets[i]))
			return 1;
	return 0;
}

/* the contract the inner helpers assert. Named after OpenBSD's
 * MUTEX_ASSERT_LOCKED (mutex(9)), and live on every platform: the
 * owner is recorded even where NCPU is 1, so efi, aarch64 and riscv64
 * -- which run this same file -- check it too.
 *
 * IPC_ASSERT_PORT is the one to reach for in a helper that touches a
 * named port and nothing else. It is the weaker demand, and a helper
 * that can honestly make it is one the split can eventually narrow;
 * IPC_ASSERT_LOCKED marks the rest.
 */
#define IPC_ASSERT_LOCKED() do {					\
	if (!ipcheld()) {						\
		char b_[96];						\
		snprintf(b_, sizeof b_, "ipclock not held: %s",		\
		    __func__);						\
		platform_abort(b_);					\
	}								\
} while (0)

#define IPC_ASSERT_PORT(p) do {						\
	if (!ipcheld_one(ipcbucket_of(p))) {				\
		char b_[96];						\
		snprintf(b_, sizeof b_, "ipclock not held: %s port %d",	\
		    __func__, (int)(p)->idx);				\
		platform_abort(b_);					\
	}								\
} while (0)

#define IPC_ASSERT_ANY() do {						\
	if (!ipcheld_any()) {						\
		char b_[96];						\
		snprintf(b_, sizeof b_, "no ipclock bucket held: %s",	\
		    __func__);						\
		platform_abort(b_);					\
	}								\
} while (0)

static void
ipclock_enter_one(struct ipcbucket *b)
{
	struct cpu *me = cpu_self();

	if (atomic_load_explicit(&b->owner, memory_order_relaxed) == me) {
		b->depth++;
		return;
	}
	lock(&b->lk);
	atomic_store_explicit(&b->owner, me, memory_order_relaxed);
	b->depth = 1;
	b->t0 = machine_cycles();
}

static void
ipclock_leave_one(struct ipcbucket *b)
{
	if (--b->depth > 0)
		return;
	b->held += machine_cycles() - b->t0;
	atomic_store_explicit(&b->owner, 0, memory_order_relaxed);
	unlock(&b->lk);
}

/* the one bucket covering p. See the obligations listed over the
 * bucket array: no other port, and no lua allocation.
 */
static void
ipclock_enter_port(struct kport *p)
{
	ipclock_enter_one(ipcbucket_of(p));
}

static void
ipclock_leave_port(struct kport *p)
{
	ipclock_leave_one(ipcbucket_of(p));
}

/* every bucket, ascending, which is the order two of the same class
 * are taken in everywhere. Releasing runs the other way for no reason
 * beyond symmetry -- release order is free.
 */
static void
ipclock_enter(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		ipclock_enter_one(&ipcbuckets[i]);
}

static void
ipclock_leave(void)
{
	for (unsigned i = NIPCLOCK; i-- > 0; )
		ipclock_leave_one(&ipcbuckets[i]);
}

static struct kport *portv[MAXPORTS];
static int porthigh;		/* one past the highest slot ever used */
static struct kport *kbdport;

/* the second terminal's keys, where the machine has a keyboard that is
 * not the console (platform_have_kbd). Separate from kbdport on
 * purpose: two terminals that shared an input port would race for every
 * keystroke, and which one got it would depend on who asked first.
 */
static struct kport *devkbdport;
static int nlive;

/* one heap per proc, in p->heap.
 *
 * This used to be a single heap behind every lua_State on the machine,
 * and the argument for that was measured and good: a proc's lua heap is
 * small, so the tail of its last chunk gets paid once per proc instead
 * of once for the machine, and one proc reusing another's freed blocks
 * lowers total fragmentation rather than raising it. Measured over 20
 * idle procs on microvm: 24646 bytes of mapped memory per proc shared
 * against 31211 per proc, 27% more, with heap waste going from 15.0%
 * to 30.5%. What lua actually asked for is identical, 21670 either
 * way -- the whole difference is chunk tails.
 *
 * A second cpu is what changes the answer, and only one clause of the
 * old argument: "there is nothing to lock either way under cooperative
 * scheduling". There is now. A shared heap needs a lock taken on every
 * lua allocation, which is the most frequent thing this kernel does --
 * so the choice is 27% more memory, or serialising every cpu on the
 * hottest path in the system. That is not a close call.
 *
 * What makes the per-proc heap need no lock of its own: a proc runs on
 * one cpu at a time, and its heap is touched only while it is running.
 * The chunk source underneath is shared and is locked (pmm.c), but a
 * heap asks it for another 8K only a handful of times in a proc's life.
 *
 * Containment is unaffected either way -- mem_used and mem_limit are
 * counted in kalloc, per proc, and never depended on the heap being
 * separate.
 *
 * What the per-proc arrangement buys back, incidentally: a proc that
 * allocates hugely and dies returns those chunks, because its whole
 * heap is destroyed with it rather than dissolving into shared free
 * lists. Where the heap is shared they dissolve, which is what they
 * did before any of this and is the price of the 232KB.
 *
 * ---- and why both arrangements are still here ----
 *
 * The 27% is worth paying where there is a second cpu to spend it on,
 * and is pure loss where there is not. efi, aarch64 and riscv64 cannot
 * have one, and neither can esp32, which is the one that cares: it is
 * a board where memory is the binding constraint.
 *
 * Measured on efi with 26 procs live, which is what that costs:
 *
 *	per-proc  1300552 bytes mapped, 50021/proc, 30.3% waste
 *	shared    1062872 bytes mapped, 40879/proc, 14.7% waste
 *
 * 232KB, and lua_live is 907060 in both -- so, again, all of it is
 * chunk tails.
 *
 * So the arrangement follows NCPU. Note what is NOT here: a lock. The
 * only combination that needs one is shared-and-parallel, and that is
 * the combination this never picks --
 *
 *	NCPU == 1   one heap, and one cpu, so nothing to lock
 *	NCPU  > 1   one heap per proc, each touched only by the cpu
 *		    running that proc, so nothing to lock
 *
 * which is why this is a memory question rather than a contention one.
 *
 * NCPU rather than platform_ncpu(), deliberately: the count is not
 * known when the first proc is made. smp_start_aps() runs after it on
 * purpose (see microvm/main.c -- an AP started before there is a proc
 * falls straight out of the dispatch loop and parks for good), so a
 * runtime test would hand the boot proc a shared heap and every later
 * proc its own. NCPU is what the build can have, which is the question
 * that stays true for the life of the machine. The cost is that a
 * microvm image booted -smp 1 keeps per-proc heaps; it is a qemu guest
 * with memory to spare, and the platform that cares is compile-time
 * uniprocessor anyway.
 */
static int nextpid;

/* the machine-wide heap, when there is one. Null where NCPU > 1, and
 * that is the test for whether a proc owns the heap it points at.
 */
static struct luaheap *shared_heap;

/* who's running right now is cpu_self()->current, which run_proc sets
 * before every lua_resume and clears after. plain C code with no
 * lua_State (stdio.c's fopen, called via liolib.c with no proc
 * identity threaded through) uses this to find out who's asking --
 * the only way to check a capability from a context where self(L)
 * isn't available at all.
 */


/* how many times kernel_run has found every proc blocked and gone to
 * a real firmware sleep. exposed via sys.stats() as an idleness
 * signal: a machine that is genuinely idle advances this steadily,
 * one that is busy-spinning (some proc always READY) never does. that
 * distinction is otherwise invisible from inside a proc -- wchan
 * sampling can't see it, because a task woken and re-blocked between
 * two samples looks identical to one that never woke.
 */


/* dispatch accounting, for answering "where does a round trip go?"
 * without guessing -- laps per round trip is what showed the ping-pong
 * never reaches the top of a lap, and so that pump_serial is no bound on
 * how long the uart fifo goes undrained. plain increments; anything
 * needing a timestamp belongs in a temporary probe, not here.
 */


/* disk gates write/append only -- read is deliberately ambient (see
 * stdio.c's fopen): the threat model is buggy lua, not hostile users
 * (AGENTS.md non-goals), nothing on the esp is confidentiality-
 * sensitive, and a stray read can't corrupt anything the way a
 * runaway write can. write still can't use the exclusive-task trick
 * cons/wire/power do (liolib.c calls our fopen() as plain C with no
 * lua_State, so there's no require()-registration boundary to
 * police); diskport is a reserved, message-free capability token,
 * holding any right to it is what fopen() checks for writes.
 */
static struct kport *diskport;

/* the scheduling capability, same shape as diskport: a kernel-owned
 * port that is never sent to or received from. holding a right to it
 * IS the authorization -- see api_set_priority.
 */
static struct kport *schedport;

static int proc_has_port(struct kproc *p, struct kport *port);

static int port_push(struct kport *port, const unsigned char *data,
    size_t len, const unsigned short *refs, int nrefs);
static int port_push_owned(struct kport *port, unsigned char *data,
    size_t len, const unsigned short *refs, const unsigned char *refrecv,
    int nrefs);

extern unsigned long long platform_ticks(void);
extern void malloc_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);
static void port_unref(struct kport *port);
/* bumped whenever a port loses a reference, which is the only way
 * sys.hungup's answer can change. see api_hangups.
 */
static unsigned long long hangup_gen;

static void wake_receivers(struct kport *port);
static void proc_kill(struct kproc *p, const char *why);
static void proc_break(struct kproc *p, const char *why);
static void proc_reap(struct kproc *p);
static void proc_rearm(struct kproc *p);
static int trace_arm(struct kproc *p, int n);
static unsigned int brokeseq;
static void wake_senders(struct kport *port);
static int reprioritize(struct kproc *p, int nrunnable);
static int count_runnable(void);
/* the scheduler lock, defined with the queues it guards. Declared here
 * because the freeze path above the scheduler takes it too.
 */
static struct lock schedlock;

/* the run queues are one structure for the machine, so every hand that
 * touches them needs this. Same shape as IPC_ASSERT_LOCKED, and it
 * answers the same weaker question -- held by anyone, not held by me --
 * for the same reason: lock.h stays below cpu identity.
 *
 * It exists because the alternative is silence. A queue mutated from a
 * syscall while another cpu is in dispatch_lap does not fail there. It
 * hands one proc to two cpus, and that arrives much later as a page
 * fault on a pointer that was good, or as lua refusing to resume a
 * coroutine that is already running.
 */
#define SCHED_ASSERT_LOCKED() do {					\
	if (!holding(&schedlock)) {					\
		char b_[96];						\
		snprintf(b_, sizeof b_, "schedlock not held: %s",	\
		    __func__);						\
		platform_abort(b_);					\
	}								\
} while (0)

static void rq_init(void);
static void rq_del(struct kproc *p);
static void rq_add(struct rqset *set, struct kproc *p);
static struct kproc *rq_take_high(struct rqset *set);
static struct kproc *rq_take_any(struct rqset *set);
static void make_ready(struct kproc *p);
static void proc_block(struct kproc *p);
static void proc_unqueue(struct kproc *p);

/* release a right that was serialized into a message but never
 * delivered (send failed, or the queue was flushed). a receive right in
 * flight was counted in nrecv when it was serialized, so it has to be
 * uncounted here -- and BEFORE port_unref, which decides port death by
 * looking at nrecv.
 */
static void
release_inflight(const unsigned short *refs, const unsigned char *refrecv,
    int n)
{
	/* caller holds ipclock, unless there is nothing to release.
	 * CONTEXT: msg_free, port_push, port_send_from_lua, and
	 * api_spawn via release_inflight_locked.
	 *
	 * The empty case is not a shortcut, it is the common one: a
	 * message carrying no rights names no port, so this touches
	 * nothing and may be called from anywhere. That is what lets the
	 * send and receive paths dispose of an ordinary message without
	 * leaving their one bucket to take all eight.
	 */
	if (n == 0)
		return;
	IPC_ASSERT_LOCKED();
	for (int i = 0; i < n; i++) {
		struct kport *port = portv[refs[i]];

		if (!port)
			continue;

		if (refrecv && refrecv[i])
			port->nrecv--;
		port_unref(port);
	}
}
static struct kport *port_new(void);
static int right_new(struct kproc *p, struct kport *port, int recv);

/* the eth task's wakeup, and the only device port here that is driven
 * by a real interrupt rather than by a poll.
 *
 * Everything above the frame wants to block until a frame arrives, and
 * until there was something to park on, every layer had to poll. This
 * is pushed only when a device has actually signalled, so a machine
 * with a quiet wire sleeps instead of asking.
 */
static struct kport *ethport;

static int have_p9;
static int have_eth;
static int have_fb;
static int have_blk;
static int have_flash;
static int have_wire;
static int have_esp;

/* cycles per millisecond, measured once at boot. platform_ticks() is a
 * raw hardware counter -- a tick count, not a time -- and its rate is
 * whatever this machine runs it at, anywhere from a GHz TSC to the
 * 62.5MHz arm virtual counter, so every duration in the system was
 * denominated in uncalibrated ticks before this existed. one 100ms
 * Stall is enough: measured stability across boots is ~4 ppm. assumes
 * a constant-rate counter, which both architectures guarantee.
 * see docs/uefi-notes.md.
 */
static unsigned long long cyc_per_ms;

/* the tsc value calibrate_clock() saw, so uptime_ms is milliseconds
 * since boot rather than since the cpu started counting. the tsc is
 * 64-bit and does not wrap on any relevant timescale -- 2^64 cycles is
 * ~195 years at 3GHz -- so this is a plain subtraction with nothing to
 * guard against. (the 24-bit ACPI PM timer, which wraps every 4.7s, is a
 * different counter and not this one.)
 */
static unsigned long long boot_tsc;

/* until calibrate_clock() runs there is no rate to divide by. anything
 * logged before then is stamped 0 rather than dividing by zero.
 */
static int clock_ready;

/* how long the rx fifo may go undrained inside the dispatch loop. 16
 * bytes at 115200 baud is ~1.39ms; a quarter of that leaves margin for a
 * proc that overruns its slice without making the check itself frequent.
 */
#define UART_DRAIN_MS 1
static unsigned long long uart_drain_cycles = 1;
static unsigned long long last_uart_drain;

/* QUANTUM_MS in cycles, set once cyc_per_ms is known */
static unsigned long long quantum_cycles;

/* how often the preempt hook samples the clock, in lua VM instructions.
 * measured at boot rather than fixed, because the right value depends
 * entirely on how fast this machine executes bytecode.
 *
 * since the hook now yields on elapsed TIME, this count is a sampling
 * rate and not a slice length: a proc can overshoot its quantum by at
 * most one period. a fixed count therefore means very different
 * behaviour on different hardware. measured here: ~32 cycles per
 * instruction, so 25000 is 176us (9% of a 2ms quantum) and 100000 is
 * 705us (35%) -- both fine. on a machine four times slower, 100000 would
 * be 2.8ms, longer than the quantum itself, and time-slicing would
 * quietly degrade back into instruction-slicing.
 *
 * calibrating targets a fixed FRACTION of the quantum instead, so the
 * overshoot bound holds on any machine.
 *
 * frequency scaling makes this approximate, and deliberately so. the TSC
 * is invariant -- constant rate whatever the P-state -- which is exactly
 * what makes it a usable clock, and exactly why it does not track how
 * fast instructions actually retire. so this measures TSC ticks per
 * instruction at whatever frequency the machine happened to be running
 * at during boot, which is typically not the frequency it will settle
 * at.
 *
 * it degrades gracefully. the quantum check itself stays correct
 * regardless: both sides of it are TSC units, so a 2ms slice is 2ms.
 * only the sampling GRANULARITY drifts, and the overshoot stays bounded
 * by one period. calibrating while throttled and then boosting just
 * means checking more often than needed; the other direction costs a
 * little more overshoot. neither is a correctness problem.
 *
 * if it ever needs to be better, the fix is self-correcting rather than
 * more calibration: the hook already knows the elapsed time, so a proc
 * that consistently overshoots could have its own period lowered.
 */
static int default_reductions = REDUCTIONS;

/* time a known number of VM instructions and pick a hook period worth
 * about an eighth of a quantum. the loop body is a local increment, so
 * roughly two instructions per iteration (ADD, FORLOOP) -- the cheapest
 * realistic opcode mix, and therefore the worst case for a period
 * measured in instructions.
 */
static void
calibrate_reductions(void)
{
	lua_State *L = luaL_newstate();

	if (!L)
		return;

	static const char src[] =
	    "local x = 0 for _ = 1, 100000 do x = x + 1 end";

	if (luaL_loadstring(L, src) != LUA_OK) {
		lua_close(L);
		return;
	}

	unsigned long long t0 = platform_ticks();

	if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
		lua_close(L);
		return;
	}

	unsigned long long d = platform_ticks() - t0;

	lua_close(L);

	unsigned long long insns = 200000;	/* ~2 per iteration */
	unsigned long long cyc_per_insn = d / insns;

	if (cyc_per_insn == 0)
		cyc_per_insn = 1;

	unsigned long long target = (quantum_cycles / 8) / cyc_per_insn;

	/* keep it sane on absurdly fast or slow machines */
	if (target < 2000)
		target = 2000;
	if (target > 500000)
		target = 500000;
	default_reductions = (int)target;
}

/* the TSC half, split out of the rest of calibration so it can run as
 * the very first thing the kernel does. it needs only BS->Stall and
 * rdtsc, both available at efi_main entry, and until it has run there is
 * no clock to stamp a log line with -- which is why the earliest boot
 * messages used to have none.
 *
 * the epoch is taken BEFORE the stall, so the 100ms calibration shows up
 * as real boot time rather than being hidden. anyone measuring boot
 * latency would otherwise be short by 100ms with nothing to explain it,
 * hence the rate line below.
 */
void
kernel_clock_init(void)
{
	boot_tsc = platform_ticks();

	unsigned long long t0 = boot_tsc;

	BS->Stall(100000);	/* 100ms */

	unsigned long long dt = platform_ticks() - t0;

	cyc_per_ms = dt / 100;
	if (cyc_per_ms == 0)
		cyc_per_ms = 1;	/* refuse to divide by zero later */
	quantum_cycles = cyc_per_ms * QUANTUM_MS;
	uart_drain_cycles = cyc_per_ms * UART_DRAIN_MS / 4;
	if (uart_drain_cycles == 0)
		uart_drain_cycles = 1;
	clock_ready = 1;
}

unsigned long long
kernel_cyc_per_ms(void)
{
	return cyc_per_ms;
}

/* milliseconds since calibrate_clock(). the one time base timers and
 * timeouts are denominated in.
 */
static unsigned long long
uptime_ms(void)
{
	if (!clock_ready)
		return 0;
	return (platform_ticks() - boot_tsc) / cyc_per_ms;
}

/* one-shot timers. sys.timer(ms) mints a port, hands the caller its
 * receive right, and records a deadline here; expire_timers() pushes one
 * message when the deadline passes and lets the port go.
 *
 * a timer is a PORT rather than a sys.sleep() call because that makes
 * recv-with-timeout fall out of thread.alt() with no new api at all:
 *
 *	thread.alt({ {port = reply}, {port = sys.timer(500)} })
 *
 * deliberately a flat unsorted array scanned linearly, not a timing
 * wheel. a wheel buys O(1) insert at the cost of real bookkeeping, and
 * earns that at thousands of timers; MAXTIMERS is 32, so that is the
 * whole array and both things we do each lap (expire the due ones, and
 * nothing else) are one pass over a tiny one. sorting would buy
 * nothing either, since insertion costs the same scan.
 *
 * resolution is the scheduler tick, ~10-15ms (see TICK_FAST_100NS and
 * docs/uefi-notes.md), so a timer may fire up to one tick late and
 * never early. that is why no per-deadline EFI timer event is armed:
 * SetTimer cannot beat 10ms anyway and every deadline in this system is
 * hundreds of milliseconds.
 */
struct ktimer {
	struct kport *port;		/* 0 = free slot */
	unsigned long long due_ms;
};

static struct ktimer timers[MAXTIMERS];

/* release slots whose port died -- the waiter closed its right or the
 * proc holding it exited. split out of expire_timers so a caller that
 * finds the table full can reclaim these without also delivering due
 * timers, which is the reactor's job and not a syscall's business.
 */
static void
reap_dead_timers(void)
{
	/* caller holds ipclock: reached both from expire_timers, which
	 * already has it, and from api_timer, which must take it. This
	 * is the nesting that made the whole-function version deadlock.
	 */
	for (int i = 0; i < MAXTIMERS; i++)
		if (timers[i].port && timers[i].port->dead) {
			port_unref(timers[i].port);
			timers[i].port = 0;
		}
}

static void
expire_timers(void)
{
	ipclock_enter();
	unsigned long long now = uptime_ms();

	reap_dead_timers();	/* cancelled ones, before looking at deadlines */
	for (int i = 0; i < MAXTIMERS; i++) {
		struct ktimer *t = &timers[i];

		if (!t->port)
			continue;
		if (now >= t->due_ms) {
			port_push(t->port, (const unsigned char *)"T", 1, 0, 0);
			port_unref(t->port);
			t->port = 0;
		}
	}
	ipclock_leave();
}

static struct kproc *
find_proc(int pid)
{
	for (int i = 0; i < MAXPROCS; i++)
		if (procv[i] && procv[i]->status != DEAD &&
		    procv[i]->id == pid)
			return procv[i];
	return 0;
}

extern void console_write(const char *s, size_t n);
void luaL_openlibs(lua_State *L);	/* our linit */

static void
kputs(const char *s)
{
	console_write(s, strlen(s));
}

/* one stamped diagnostic line, terminated here so callers cannot forget.
 *
 * the format is shared with lib/log.lua: two producers, one transcript.
 * the stamp is taken when the line is EMITTED, which matters because the
 * lua side reaches the console through a port and is therefore delivered
 * later than this synchronous path -- so display order and real order
 * differ, and only the stamps recover it.
 */
void
kernel_log(const char *s)
{
	unsigned long long ms = uptime_ms();
	char buf[320];

	snprintf(buf, sizeof buf, "[%5llu.%03llu] %s\n", ms / 1000,
	    ms % 1000, s);
	kputs(buf);
}

/* ---- ports and rights ---- */

static struct kport *
port_new(void)
{
	for (int i = 0; i < MAXPORTS; i++)
		if (!portv[i]) {
			struct kport *port = malloc(sizeof *port);

			if (!port)
				return 0;
			memset(port, 0, sizeof *port);
			port->idx = (unsigned short)i;
			port->used = 1;
			TAILQ_INIT(&port->waiters);
			portv[i] = port;
			if (i >= porthigh)
				porthigh = i + 1;
			return port;
		}
	return 0;
}

static void port_unref(struct kport *port);

/* free one message, releasing the in-flight right refs it carries */
static void
msg_free(struct kmsg *m)
{
	release_inflight(m->refs, m->refrecv, m->nrefs);
	free(m->data);
	free(m);
}

/* flush the queue (delivery no longer possible) */
static void
port_flush(struct kport *port)
{
	struct kmsg *m = port->head;

	port->head = port->tail = 0;
	port->qbytes = 0;
	while (m) {
		struct kmsg *next = m->next;

		msg_free(m);
		m = next;
	}
}

/* drop one reference; the last ref frees the port. dropping the last
 * *receive* right marks the port dead and flushes the queue -- nobody
 * can ever take those messages. flushing may recursively unref other
 * ports whose only rights were in the flushed messages.
 */
static void
port_unref(struct kport *port)
{
	/* caller holds ipclock.
	 * CONTEXT: expire_timers, port_new, reap_dead_timers,
	 * release_inflight, right_drop.
	 */
	IPC_ASSERT_LOCKED();
	if (--port->nrights <= 0) {
		/* flush first: it can unref other ports, and one of those
		 * could be this one's last reference from a queued message
		 */
		port_flush(port);
		portv[port->idx] = 0;
		free(port);
		return;
	}
	if (port->nrecv == 0 && !port->dead) {
		port->dead = 1;
		port_flush(port);
	}
	/* a dropped reference can make sys.hungup() true for whoever is
	 * left, so anyone parked on this port has to re-check. without this
	 * a pipe reader blocked for data would sleep through its writer's
	 * exit and never see eof.
	 */
	hangup_gen++;
	wake_receivers(port);
	/* the same for writers: a reader going away means a full port will
	 * never drain, so anyone parked for room has to wake and learn
	 * from its next send that the port is dead. exact twin of the eof
	 * case above, and without it a blocked writer outlives its reader
	 * forever.
	 */
	wake_senders(port);
}

static int rights_high;

/* the slot a handle names, or null if it is out of range or lives in an
 * overflow array this proc has never needed. never allocates: it is on
 * every send and receive, with a handle the caller may have made up.
 */
static struct right *
right_slot(struct kproc *p, int h)
{
	if (h < 0 || h >= MAXRIGHTS)
		return 0;
	if (h < NRIGHTS_INLINE)
		return &p->rights[h];
	if (!p->xrights)
		return 0;
	return &p->xrights[h - NRIGHTS_INLINE];
}

/* the same, allocating the overflow array on first need */
static struct right *
right_slot_grow(struct kproc *p, int h)
{
	if (h < 0 || h >= MAXRIGHTS)
		return 0;
	if (h < NRIGHTS_INLINE)
		return &p->rights[h];
	if (!p->xrights) {
		size_t n = MAXRIGHTS - NRIGHTS_INLINE;

		p->xrights = malloc(n * sizeof *p->xrights);
		if (!p->xrights)
			return 0;
		memset(p->xrights, 0, n * sizeof *p->xrights);
	}
	return &p->xrights[h - NRIGHTS_INLINE];
}

static int
right_new(struct kproc *p, struct kport *port, int recv)
{
	/* CALLER NEEDS NO LOCK, and this is the one helper here that
	 * genuinely needs none.
	 *
	 * It writes two things. p's right table belongs to p, and only p
	 * runs on any cpu at a time. port->nrights is atomic, and taking
	 * a reference cannot destroy anything -- the caller already holds
	 * one, or the message it is deserializing does.
	 *
	 * That is what lets deserialize run outside every bucket, which
	 * is the whole point: turning a message into lua values allocates
	 * lua memory, and the collector reaches api_close from there.
	 *
	 * CONTEXT: api_newport, api_sendright, api_timer, api_spawn,
	 * deserialize, grant_named, proc_new, release_inflight,
	 * spawn_driver.
	 */
	/* start where a free slot was last seen. without it a proc holding
	 * five hundred rights rescans all of them for each new one, which is
	 * quadratic for exactly the case a large MAXRIGHTS is meant to allow
	 * -- a supervisor holding a right per child.
	 */
	for (int i = p->rhint; i < MAXRIGHTS; i++) {
		struct right *r = right_slot_grow(p, i);

		if (!r)
			return -1;
		if (!r->used) {
			if (i + 1 > rights_high)
				rights_high = i + 1;
			r->used = 1;
			r->port = port;
			r->recv = recv;
			port->nrights++;
			if (recv)
				port->nrecv++;
			p->rhint = i + 1;
			if (i + 1 > p->rhigh)
				p->rhigh = i + 1;
			return i;
		}
	}
	return -1;
}

static void
right_drop(struct right *r)
{
	/* caller holds ipclock.
	 * CONTEXT: api_close, proc_detach, proc_new.
	 */
	IPC_ASSERT_LOCKED();
	struct kport *port = r->port;

	r->used = 0;
	if (r->recv)
		port->nrecv--;
	port_unref(port);
}

/* grant a named capability: take a right the ordinary way (first free
 * slot) and record what it was called, in the proc's grant list, so lua
 * can look the handle up by name through sys.granted(). a NULL port is a
 * no-op -- exactly the "this capability doesn't exist this boot" case.
 * the list has no fixed ceiling on purpose: a fixed array here once
 * silently dropped grants past its size, and a missing grant reads to a
 * client as the device being broken (the dhcpd overflow).
 */
static void
grant_named(struct kproc *p, const char *name, struct kport *port, int recv)
{
	if (!port)
		return;

	int h = right_new(p, port, recv);

	if (h < 0)
		return;

	struct grant *g = malloc(sizeof *g);

	if (!g) {
		/* the right was taken; drop it rather than leave an anonymous
		 * handle behind on an allocation that failed.
		 */
		struct right *r = right_slot(p, h);

		if (r)
			right_drop(r);
		return;
	}
	g->name = name;
	g->handle = h;
	SLIST_INSERT_HEAD(&p->grants, g, e);
}

static struct right *
right_get(struct kproc *p, lua_Integer h)
{
	struct right *r = right_slot(p, (int)h);

	if (!r || !r->used)
		return 0;
	return r;
}

/* ---- serializer ----
 * tags: N nil, T true, F false, I int64, D double, S u32+bytes,
 * B u32 npairs then k,v..., R u8 portindex u8 recv
 */

struct wbuf {
	unsigned char *p;
	size_t len, cap;
	/* ports referenced by rights serialized into this message; each
	 * holds a ref taken at serialize time (released on send failure,
	 * or by msg_free once delivered/flushed)
	 */
	unsigned short refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];
	int nrefs;
};

static int
wput(struct wbuf *w, const void *src, size_t n)
{
	if (w->len + n > w->cap) {
		size_t need = w->len + n;

		/* the limit belongs to the message, not to the growth
		 * policy. doubling is free to overshoot MAXMSG and get
		 * clamped; only a message that genuinely does not fit is
		 * refused. while every cap was a power of two the two
		 * tests agreed, and pre-sizing from a hint is what makes
		 * an arbitrary cap -- and an overshoot -- possible.
		 */
		if (need > MAXMSG)
			return -1;

		size_t ncap = w->cap ? w->cap * 2 : 256;

		while (ncap < need)
			ncap *= 2;
		if (ncap > MAXMSG)
			ncap = MAXMSG;
		unsigned char *np = realloc(w->p, ncap);

		if (!np)
			return -1;
		w->p = np;
		w->cap = ncap;
	}
	memcpy(w->p + w->len, src, n);
	w->len += n;
	return 0;
}

static int
wbyte(struct wbuf *w, unsigned char c)
{
	return wput(w, &c, 1);
}

/* pre-size a wbuf, so the common message does not grow.
 *
 * Strictly a hint: wput still grows whenever this comes up short, so
 * being wrong costs one realloc and never correctness. That is what
 * lets it skip serialize's type dispatch entirely -- it does not have
 * to agree with serialize about anything, and cannot drift out of sync
 * with it -- and look only for the thing that actually makes a message
 * big, which is a string.
 *
 * One level deep on purpose. The shape this is for is a table wrapping
 * one payload, which is every mnt reply; a nested table contributes a
 * guess and grows from there if it was wrong.
 *
 * lua_tolstring only where the type is already string: on a key it
 * would convert a number in place, and lua_next does not survive that.
 */
static size_t
sizehint(lua_State *L, int idx)
{
	size_t total = 16, n;

	idx = lua_absindex(L, idx);
	if (lua_type(L, idx) == LUA_TSTRING) {
		lua_tolstring(L, idx, &n);
		return n + 16;
	}
	if (lua_type(L, idx) != LUA_TTABLE)
		return 0;

	lua_pushnil(L);
	while (lua_next(L, idx)) {
		if (lua_type(L, -1) == LUA_TSTRING) {
			lua_tolstring(L, -1, &n);
			total += n + 8;
		} else
			total += 16;
		if (lua_type(L, -2) == LUA_TSTRING) {
			lua_tolstring(L, -2, &n);
			total += n + 8;
		} else
			total += 16;
		lua_pop(L, 1);
	}
	return total;
}

/* take the hint. Failure is not reported because there is nothing to
 * report: the buffer is simply not pre-sized and wput does what it
 * always did.
 */
static void
wreserve(struct wbuf *w, size_t n)
{
	if (n < 256 || n > MAXMSG || w->cap >= n)
		return;

	unsigned char *p = realloc(w->p, n);

	if (p) {
		w->p = p;
		w->cap = n;
	}
}

static int
serialize(lua_State *L, int idx, struct wbuf *w, struct kproc *sender,
    int depth)
{
	if (depth > MAXDEPTH)
		return -1;
	idx = lua_absindex(L, idx);

	switch (lua_type(L, idx)) {
	case LUA_TNIL:
		return wbyte(w, 'N');
	case LUA_TBOOLEAN:
		return wbyte(w, lua_toboolean(L, idx) ? 'T' : 'F');
	case LUA_TNUMBER:
		if (lua_isinteger(L, idx)) {
			lua_Integer v = lua_tointeger(L, idx);

			if (wbyte(w, 'I'))
				return -1;
			return wput(w, &v, sizeof v);
		} else {
			lua_Number v = lua_tonumber(L, idx);

			if (wbyte(w, 'D'))
				return -1;
			return wput(w, &v, sizeof v);
		}
	case LUA_TSTRING: {
		size_t n;
		const char *s = lua_tolstring(L, idx, &n);
		unsigned int len = n;

		if (wbyte(w, 'S') || wput(w, &len, sizeof len))
			return -1;
		return wput(w, s, n);
	}
	case LUA_TTABLE: {
		/* {__right = handle} sends a right, and COPIES it: the port
		 * is taken out of the sender's handle and the handle stays
		 * live and still counts against MAXRIGHTS. A caller minting
		 * one per request must therefore close it, which is what
		 * lib/thread.lua's rpc is for -- forgetting has cost this
		 * tree three separate bugs, each one surfacing far from the
		 * leak as a driver that mysteriously stopped working.
		 *
		 * if __right is present but not an integer handle it's a
		 * mistake (e.g. a float); refuse it rather than silently
		 * shipping the table as data and dropping the intended
		 * capability.
		 */
		lua_getfield(L, idx, "__right");
		if (!lua_isnil(L, -1)) {
			if (!lua_isinteger(L, -1)) {
				lua_pop(L, 1);
				return -1;
			}
			struct right *r = right_get(sender,
			    lua_tointeger(L, -1));

			lua_pop(L, 1);
			if (!r || w->nrefs >= MAXMSGRIGHTS)
				return -1;
			unsigned short pi = r->port->idx;

			if (wbyte(w, 'R') || wput(w, &pi, sizeof pi))
				return -1;
			if (wbyte(w, (unsigned char)r->recv))
				return -1;
			/* in-flight refs keep the port alive in the queue --
			 * and a receive right in flight must count toward
			 * nrecv straight away. it does not exist in the
			 * receiver yet, so without this the sender closing
			 * its own copy drops nrecv to zero, marks the port
			 * dead and FLUSHES the queue, while a perfectly good
			 * receive right is still on its way to its owner.
			 */
			w->refrecv[w->nrefs] = (unsigned char)r->recv;
			w->refs[w->nrefs++] = pi;
			r->port->nrights++;
			if (r->recv)
				r->port->nrecv++;
			return 0;
		}
		lua_pop(L, 1);

		unsigned int n = 0;
		size_t countpos = w->len;

		if (wbyte(w, 'B') || wput(w, &n, sizeof n))
			return -1;
		lua_pushnil(L);
		while (lua_next(L, idx)) {
			if (serialize(L, -2, w, sender, depth + 1) ||
			    serialize(L, -1, w, sender, depth + 1)) {
				lua_pop(L, 2);
				return -1;
			}
			lua_pop(L, 1);
			n++;
		}
		memcpy(w->p + countpos + 1, &n, sizeof n);
		return 0;
	}
	default:
		return -1;	/* functions, userdata: no travel */
	}
}

static int
deserialize(lua_State *L, const unsigned char *p, size_t len, size_t *off,
    struct kproc *receiver, int depth)
{
	if (depth > MAXDEPTH)
		return -1;
	if (*off >= len)
		return -1;
	unsigned char tag = p[(*off)++];

	switch (tag) {
	case 'N':
		lua_pushnil(L);
		return 0;
	case 'T':
		lua_pushboolean(L, 1);
		return 0;
	case 'F':
		lua_pushboolean(L, 0);
		return 0;
	case 'I': {
		lua_Integer v;

		if (*off + sizeof v > len)
			return -1;
		memcpy(&v, p + *off, sizeof v);
		*off += sizeof v;
		lua_pushinteger(L, v);
		return 0;
	}
	case 'D': {
		lua_Number v;

		if (*off + sizeof v > len)
			return -1;
		memcpy(&v, p + *off, sizeof v);
		*off += sizeof v;
		lua_pushnumber(L, v);
		return 0;
	}
	case 'S': {
		unsigned int n;

		if (*off + sizeof n > len)
			return -1;
		memcpy(&n, p + *off, sizeof n);
		*off += sizeof n;
		if (*off + n > len)
			return -1;
		lua_pushlstring(L, (const char *)p + *off, n);
		*off += n;
		return 0;
	}
	case 'B': {
		unsigned int n;

		if (*off + sizeof n > len)
			return -1;
		memcpy(&n, p + *off, sizeof n);
		*off += sizeof n;
		/* each pair is >= 2 bytes (two tags); reject a count that
		 * can't fit in what's left so a corrupt n can't drive a
		 * huge lua_createtable preallocation.
		 */
		if (n > (len - *off) / 2)
			return -1;
		lua_createtable(L, 0, n);
		for (unsigned int i = 0; i < n; i++) {
			int rc = deserialize(L, p, len, off, receiver,
			    depth + 1);

			if (rc == 0)
				rc = deserialize(L, p, len, off, receiver,
				    depth + 1);
			/* keep the reason: a nested right that could not
			 * be made is still a resource failure.
			 */
			if (rc)
				return rc;
			lua_settable(L, -3);
		}
		return 0;
	}
	case 'R': {
		if (*off + 3 > len)
			return -1;
		unsigned short pi;

		if (*off + sizeof pi > len)
			return -1;
		memcpy(&pi, p + *off, sizeof pi);
		*off += sizeof pi;

		unsigned char recv = p[(*off)++];

		if (pi >= MAXPORTS || !portv[pi])
			return -1;

		int h = right_new(receiver, portv[pi], recv);

		/* a full rights table is a local limit, not bad bytes */
		if (h < 0)
			return -2;	/* out of rights, not bad bytes */
		lua_createtable(L, 0, 1);
		lua_pushinteger(L, h);
		lua_setfield(L, -2, "__right");
		return 0;
	}
	default:
		return -1;
	}
}

/* ---- message delivery ---- */

/* attach p to port's wait list. returns 0 only if an allocation failed,
 * which the caller must report rather than silently not waiting -- a proc
 * that believes it is blocked but is on no list never wakes.
 */
static int
wait_add(struct kproc *p, struct kport *port, int send)
{
	/* caller holds the bucket covering `port`.
	 * CONTEXT: the five blocking calls, all of which hold it
	 * across the test that decided to sleep.
	 *
	 * Per-port rather than every bucket, because that is all this
	 * touches: one port's waiter list, and p's own list, which
	 * belongs to the running proc. alt names several ports but one
	 * per call, so this is the right demand there too.
	 */
	IPC_ASSERT_PORT(port);
	struct waiter *w;

	if (!p->w0used) {
		p->w0used = 1;
		w = &p->w0;
	} else {
		w = malloc(sizeof *w);
		if (!w)
			return 0;
	}
	w->p = p;
	w->port = port;
	w->send = send;
	w->onport = 1;
	TAILQ_INSERT_TAIL(&port->waiters, w, pq);
	SLIST_INSERT_HEAD(&p->waiters, w, pw);
	return 1;
}

/* drop every wait this proc holds. called on death and by alt before it
 * builds a new set, so it has to be safe to call when the list is
 * already empty.
 *
 * This is the WIDE operation: it reaches every port the proc waits on,
 * so it demands every bucket. wait_reap is the narrow form and is what
 * the wake path uses.
 */
static void
wait_clear(struct kproc *p)
{
	/* caller holds ipclock.
	 * CONTEXT: alt, proc_detach.
	 */
	IPC_ASSERT_LOCKED();
	while (!SLIST_EMPTY(&p->waiters)) {
		struct waiter *w = SLIST_FIRST(&p->waiters);

		SLIST_REMOVE_HEAD(&p->waiters, pw);
		if (w->onport)
			TAILQ_REMOVE(&w->port->waiters, w, pq);
		if (w == &p->w0)
			p->w0used = 0;
		else
			free(w);
	}
}

/* collect the waits left over from the last block, on the proc's own
 * cpu and just before it is resumed.
 *
 * This is the half of the wake that the waker deliberately does not do.
 * A waker holds one port's bucket, so the only waiter list it may touch
 * is that port's -- and a proc in an alt is on several. So the waker
 * unlinks the one it woke on and leaves the rest, and the proc collects
 * them here, taking each port's bucket in turn and holding exactly one
 * at a time.
 *
 * Linux's poll works the same way round: pollwake touches the one wait
 * queue it was called on, and poll_freewait walks the rest from the
 * woken task. Because only one lock is ever held here, there is no
 * order to violate between them.
 *
 * Also where `woken` is cleared, which is what re-arms the proc to be
 * claimed the next time it blocks. Nothing may claim it in between,
 * because a running proc is not BLOCKED.
 */
static void
wait_reap(struct kproc *p)
{
	while (!SLIST_EMPTY(&p->waiters)) {
		struct waiter *w = SLIST_FIRST(&p->waiters);

		SLIST_REMOVE_HEAD(&p->waiters, pw);
		if (w->onport) {
			ipclock_enter_port(w->port);
			/* re-read under the bucket: a waker may have
			 * unlinked it between the test and the lock.
			 */
			if (w->onport) {
				TAILQ_REMOVE(&w->port->waiters, w, pq);
				w->onport = 0;
			}
			ipclock_leave_port(w->port);
		}
		if (w == &p->w0)
			p->w0used = 0;
		else
			free(w);
	}
	atomic_store_explicit(&p->woken, 0, memory_order_relaxed);
}

/* take the right to wake this proc, or find that another port already
 * has. See kproc.woken.
 */
static int
wake_claim(struct kproc *p)
{
	int expect = 0;

	return atomic_compare_exchange_strong_explicit(&p->woken, &expect, 1,
	    memory_order_acq_rel, memory_order_relaxed);
}

static void
wake_receivers(struct kport *port)
{
	/* caller holds the bucket covering `port`.
	 * CONTEXT: port_push_owned and port_unref. Touches another
	 * proc's run queue, and this port's waiter list -- but no
	 * other port's, which is what lets a sender hold one bucket.
	 */
	IPC_ASSERT_PORT(port);
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (w->send || p->status != BLOCKED)
			continue;
		if (!wake_claim(p))
			continue;	/* another port got there first */
		TAILQ_REMOVE(&port->waiters, w, pq);
		w->onport = 0;
		make_ready(p);
	}
}

/* the mirror of wake_receivers: anyone parked for ROOM on this port.
 *
 * called from exactly two places, and both are required. draining a
 * message (api_tryrecv) frees space, which is the ordinary wakeup. a
 * port dying (port_unref) is the other one -- without it a writer
 * blocked on a full port whose reader just vanished would sleep
 * forever, which is the send-side twin of the eof problem the
 * wake_receivers call in port_unref exists to solve.
 *
 * a spurious wake is harmless: sys.sendblock only promises the port
 * MIGHT have room, and every caller loops on the send anyway (see
 * lib/prog.lua's PipeStream:write), exactly as api_block's callers
 * loop on tryrecv.
 */
static void
wake_senders(struct kport *port)
{
	/* caller holds the bucket covering `port`.
	 * CONTEXT: port_pop_to_lua and port_unref. Same reach as
	 * wake_receivers.
	 */
	IPC_ASSERT_PORT(port);
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (!w->send || p->status != BLOCKED)
			continue;
		if (!wake_claim(p))
			continue;
		TAILQ_REMOVE(&port->waiters, w, pq);
		w->onport = 0;
		make_ready(p);
	}
}

/* queue a message. refs/nrefs are in-flight right refs (may be null).
 * a dead port silently drops -- erlang semantics, the sender learns
 * from the monitor, not the send.
 */
/* takes ownership of `data` only when it returns 0. On any refusal the
 * caller still owns both the buffer and the in-flight refs, and must
 * free the one and release the other.
 *
 * That is the awkward half of the contract and it is deliberate. This
 * runs under one bucket -- the one covering `port` -- and releasing a
 * reference does not: it can drop a port to zero and flush its queue,
 * which reaches other ports under other buckets, so it demands all of
 * them. A narrow region cannot widen, so the disposal has to happen
 * after the caller leaves. release_inflight is a no-op for a message
 * carrying no rights, which is nearly all of them, so the usual cost of
 * this arrangement is a branch.
 *
 * this exists so a serialized message is built once and queued without a
 * second copy. the serializer already malloc'd exactly the buffer we
 * want; copying it into a flexible array on the kmsg meant every send
 * paid a full memcpy of its own payload for nothing.
 */
static int
port_push_owned(struct kport *port, unsigned char *data, size_t len,
    const unsigned short *refs, const unsigned char *refrecv, int nrefs)
{
	/* caller holds the bucket covering `port`.
	 * CONTEXT: port_push, notify_exit, port_send_from_lua.
	 */
	IPC_ASSERT_PORT(port);
	if (port->dead) {
		port->ndrop_dead++;
		return -3;
	}

	if (port->qbytes + len > MAXQUEUE) {
		port->ndrop_full++;
		return -2;		/* full, distinct from out of memory */
	}

	struct kmsg *m = malloc(sizeof *m);

	if (!m)
		return -1;
	m->next = 0;
	m->len = len;
	m->data = data;
	m->nrefs = nrefs;
	for (int i = 0; i < nrefs; i++) {
		m->refs[i] = refs[i];
		m->refrecv[i] = refrecv ? refrecv[i] : 0;
	}
	if (port->tail)
		port->tail->next = m;
	else
		port->head = m;
	port->tail = m;
	port->qbytes += len;
	if (port->qbytes > port->qpeak)
		port->qpeak = port->qbytes;
	port->nsent++;
	wake_receivers(port);
	return 0;
}

/* copying form, for callers whose bytes are on the stack or in a string
 * literal -- the device pumps and the timer tick. they push a handful of
 * bytes, so the copy is not worth avoiding.
 */
static int
port_push(struct kport *port, const unsigned char *data, size_t len,
    const unsigned short *refs, int nrefs)
{
	/* caller holds ipclock.
	 * CONTEXT: any outer ipc entry point.
	 */
	IPC_ASSERT_LOCKED();
	unsigned char *copy = malloc(len);

	if (!copy) {
		release_inflight(refs, 0, nrefs);
		return -1;
	}
	memcpy(copy, data, len);

	int rc = port_push_owned(port, copy, len, refs, 0, nrefs);

	if (rc) {
		release_inflight(refs, 0, nrefs);
		free(copy);
	}
	/* a dead port is not this caller's failure -- see the erlang
	 * note above -- so it reads as success, which is what the
	 * refusal code used to be folded into.
	 */
	return rc == -3 ? 0 : rc;
}

/* remove the file half of io; the console half stays. see kernel.h on
 * why this is callable from linit.c as well as proc_new.
 */
void
kernel_strip_io(lua_State *L)
{
	static const char *const gone[] = {
		"open", "lines", "input", "output", "popen", "tmpfile", NULL
	};

	if (!lua_istable(L, -1))
		return;
	for (int i = 0; gone[i]; i++) {
		lua_pushnil(L);
		lua_setfield(L, -2, gone[i]);
	}
}

/* debug.sethook is a preemption escape, and the only member of the debug
 * library that is one.
 *
 * The kernel's instruction budget is a count hook armed once, in
 * proc_new -- it is never re-armed on resume. So debug.sethook(), with
 * no arguments, clears it on the running coroutine and the proc can then
 * spin forever with nothing left to interrupt it.
 *
 * Coroutines are not a way in: lua_newthread copies hook, mask and count
 * from its parent, so a bare coroutine.create() spinner is preempted and
 * contained. Checked, not assumed -- debug.gethook() on a fresh
 * coroutine reports the same external hook and the same count. That is not a
 * contained failure, it is the machine: measured, a proc doing
 * `debug.sethook() while true do end` takes the console, the network and
 * every other proc down with it.
 *
 * The rest of the library stays, and deliberately. debug.traceback is
 * what init.lua's repl reports errors with, and it is the only way to
 * see inside a parked lib/thread coroutine -- sys.stack walks the proc's
 * main coroutine and cannot descend into one. Removing the diagnostics
 * to close a hole in the scheduler would be a bad trade. Everything else
 * in debug (setlocal, setupvalue, setmetatable, getregistry) reaches
 * only the proc's own lua_State, which is the blast radius a proc
 * already has; this repo's threat model is buggy lua, not hostile users.
 */
void
kernel_strip_debug(lua_State *L)
{
	if (!lua_istable(L, -1))
		return;
	lua_pushnil(L);
	lua_setfield(L, -2, "sethook");
}

int
kernel_current_is_boot(void)
{
	return cpu_self()->current && cpu_self()->current->priv == PRIV_BOOT;
}

/* ---- coroutine.wrap, made transparent to preemption ----
 *
 * preempt_hook stops whatever state is running and yields it, and
 * lua_yield unwinds to the RESUMER of that state. For a thread that is
 * thread.run, which knows what the yield meant. For an ordinary
 * coroutine it is whoever called it -- and `for v in seq(n)` reads a
 * yield of no values as the generator being finished, so the loop ends
 * early and the caller is handed short data with no error at all.
 *
 * Measured before this existed, items delivered out of 10 by work done
 * per item: 10 at 1, 10 at 100, 3 at 10000, none at 200000. A generator
 * was usable only while it stayed under a quantum.
 *
 * The fix is not to stop preempting -- that is what stops a proc
 * spinning inside a coroutine from holding the machine, and it is the
 * only thing that does (see the walk-out in preempt_hook and
 * test_nesting). It is to resume again rather than believe the yield.
 * The coroutine's state is untouched by being stopped, so resuming
 * continues at the instruction it was stopped at, and the caller never
 * learns it happened.
 *
 * Yielding OURSELVES first is what keeps that from defeating the
 * preemption it hides: the level above -- thread.run, or the kernel --
 * gets its chance to deschedule, and both resume in place, so control
 * comes back here and the generator carries on. The proc still honours
 * its quantum; only the generator is spared knowing about it.
 *
 * Nested wraps compose because the explicit yield below marks THIS
 * state preempted too, so an enclosing wrap treats it the same way
 * rather than reporting a finished generator to its own caller.
 *
 * coroutine.resume is deliberately left alone. It is the interface a
 * scheduler uses -- lib/thread.lua's resume_one is exactly this -- and
 * a scheduler has to see the preemption to do its job. Swallowing it
 * there would put a table allocation on the hottest path in the system
 * and leave run() unable to tell a cut thread from a parked one.
 */
static int kernel_cowrap_resume(lua_State *L, lua_State *co, int narg);

static int
kernel_cowrap_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_State *co = lua_tothread(L, lua_upvalueindex(1));

	(void)status;
	(void)ctx;
	/* no arguments on the way back in: the coroutine is stopped
	 * mid-instruction, not waiting at a yield for a value.
	 */
	return kernel_cowrap_resume(L, co, 0);
}

static int
kernel_cowrap_resume(lua_State *L, lua_State *co, int narg)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(co);

	for (;;) {
		int nres, st;

		if (!lua_checkstack(co, narg))
			return luaL_error(L, "too many arguments to resume");
		lua_xmove(L, co, narg);
		kx->preempted = 0;
		st = lua_resume(co, L, narg, &nres);
		if (st != LUA_OK && st != LUA_YIELD) {
			int s = lua_status(co);

			if (s != LUA_OK && s != LUA_YIELD) {
				s = lua_closethread(co, L);
				lua_xmove(co, L, 1);
			} else {
				lua_xmove(co, L, 1);
			}
			if (s != LUA_ERRMEM &&
			    lua_type(L, -1) == LUA_TSTRING) {
				luaL_where(L, 1);
				lua_insert(L, -2);
				lua_concat(L, 2);
			}
			return lua_error(L);
		}
		if (!lua_checkstack(L, nres + 1)) {
			lua_pop(co, nres);
			return luaL_error(L, "too many results to resume");
		}
		lua_xmove(co, L, nres);
		if (st != LUA_YIELD || !kx->preempted)
			return nres;

		/* stopped by the hook. Nothing was yielded -- drop it
		 * anyway rather than trust the count -- and go round.
		 */
		lua_pop(L, nres);
		kx->preempted = 0;
		if (!lua_isyieldable(L)) {
			/* nowhere to hand the quantum to, so carry on
			 * rather than report a generator that is not
			 * finished as finished. Correctness first; the
			 * proc is descheduled at the next chance.
			 */
			narg = 0;
			continue;
		}
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
		return lua_yieldk(L, 0, 0, kernel_cowrap_k);
	}
}

static int
kernel_cowrap_aux(lua_State *L)
{
	lua_State *co = lua_tothread(L, lua_upvalueindex(1));

	return kernel_cowrap_resume(L, co, lua_gettop(L));
}

static int
kernel_cowrap(lua_State *L)
{
	lua_State *co;

	luaL_checktype(L, 1, LUA_TFUNCTION);
	co = lua_newthread(L);
	lua_pushvalue(L, 1);
	lua_xmove(L, co, 1);
	lua_pushcclosure(L, kernel_cowrap_aux, 1);
	return 1;
}

/* the coroutine table is on top of the stack. */
void
kernel_wrap_coroutine(lua_State *L)
{
	if (!lua_istable(L, -1))
		return;
	lua_pushcfunction(L, kernel_cowrap);
	lua_setfield(L, -2, "wrap");
}

/* ---- lua api (proc pointer lives in the state's extra space) ---- */

/* the state a per-state record belongs to: the record sits immediately
 * before it, which is what lua_getextraspace computes in reverse.
 */
static lua_State *
kx_state(struct kextra *kx)
{
	return (lua_State *)((char *)kx + LUA_EXTRASPACE);
}

static struct kproc *
self(lua_State *L)
{
	return *(struct kproc **)lua_getextraspace(L);
}

/* serialize the value at `idx` and queue it on r's port. shared by
 * api_send and api_call, which differ only in what they do afterwards.
 * the wbuf is disposed of on every path, success or not.
 *
 * TAKES NO LOCK ON ENTRY, and that is the point: the serializer is the
 * expensive half of a send and it is also the half that must not run
 * under a bucket, because building the message allocates lua memory and
 * the collector reaches api_close from there. So it runs first, with
 * nothing held, and only the queue insert and the wakeup happen under
 * the one bucket covering r->port.
 *
 * The references serialize mints are what make that safe. They are
 * taken with no lock, which is sound because taking one cannot destroy
 * anything, and they keep every port the message names alive for as
 * long as the message exists.
 */
enum { SEND_OK = 0, SEND_UNSERIALIZABLE, SEND_DEAD, SEND_FULL, SEND_NOMEM };

static int
port_send_from_lua(lua_State *L, struct kproc *p, struct right *r, int idx)
{
	struct wbuf w = { 0 };
	int rc;

	wreserve(&w, sizehint(L, idx));
	if (serialize(L, idx, &w, p, 0)) {
		/* release refs taken for rights serialized before the
		 * failure point
		 */
		rc = SEND_UNSERIALIZABLE;
		goto discard;
	}

	ipclock_enter_port(r->port);
	rc = port_push_owned(r->port, w.p, w.len, w.refs, w.refrecv, w.nrefs);
	ipclock_leave_port(r->port);

	switch (rc) {
	case 0:
		return SEND_OK;
	case -2:
		rc = SEND_FULL;
		break;
	case -3:
		rc = SEND_DEAD;
		break;
	default:
		rc = SEND_NOMEM;
		break;
	}
discard:
	/* outside the bucket, because releasing a reference needs all of
	 * them. Free of charge unless the message carried rights.
	 */
	if (w.nrefs) {
		ipclock_enter();
		release_inflight(w.refs, w.refrecv, w.nrefs);
		ipclock_leave();
	}
	free(w.p);
	return rc;
}

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	int rc;

	luaL_checkany(L, 2);				/* raises; before */

	/* no lock here at all: the right lookup reads this proc's own
	 * table, which only this proc touches, and port_send_from_lua
	 * takes the one bucket it needs for as long as it needs it.
	 */
	r = right_get(p, h);
	rc = r ? port_send_from_lua(L, p, r, 2) : 0;

	if (!r)
		return luaL_error(L, "bad right");

	if (rc == SEND_UNSERIALIZABLE)
		return luaL_error(L, "unserializable message");
	if (rc == SEND_DEAD) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "dead");
		return 2;
	}

	/* a full queue RETURNS rather than raising, so it is an ordinary
	 * outcome the caller chooses a policy for, distinguishable from
	 * "dead" by the second value. it used to raise, and that made the
	 * choice for everyone: a pipe writer died at MAXQUEUE instead of
	 * applying backpressure, which is what a pipe is supposed to do.
	 *
	 * blocking here in the KERNEL would be the wrong fix. a file
	 * server replying to a client whose port is full would block, and
	 * one slow reader would then wedge that server for every other
	 * client. the kernel cannot tell a pipe write from a server
	 * reply, so it must not pick: it reports, and lua decides. that is
	 * the same split the receive side already makes -- sys.tryrecv
	 * plus sys.block, with the blocking loop living in lua.
	 */
	if (rc == SEND_FULL) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "full");
		return 2;
	}
	if (rc == SEND_NOMEM)
		return luaL_error(L, "out of memory queueing message");
	lua_pushboolean(L, 1);
	return 1;
}

/* BLOCKED_TWICE_MSG, and why the test that raises it is spelled out at
 * each of its four call sites now rather than living in a helper: the
 * test reads shared state and has to sit inside the same region as the
 * wait_add it guards, while the raise has to sit outside it, because
 * luaL_error longjmps. One helper cannot be in both places.
 *
 * A proc about to block must hold no waits, because a proc that is
 * blocked is not running and so cannot ask to block again. Reaching
 * here with waits already attached means the last block never actually
 * stopped this proc, and the only way that happens is a lua_yield that
 * did not unwind to the kernel: sys.block called from inside a
 * coroutine yields to whoever resumed it -- lib/los/thread.lua's
 * scheduler -- while the kernel has already marked the proc BLOCKED and
 * taken it off the run queue. The thread scheduler then runs the next
 * thread, which blocks again, and now one port carries two waiters for
 * one proc. wake_receivers saves the next waiter before wait_clear
 * frees every wait the proc holds, so it walks a freed entry: a #GP,
 * far from the mistake.
 *
 * An error rather than a panic, since any lua code can reach it. The
 * fix is always to park instead -- los.thread's park() and recv() pick
 * the right one via inthread(). Note that a second copy of that module
 * loaded under another name is a second scheduler with its own
 * _current, so inthread() answers no and lands here.
 *
 * SLIST_EMPTY rather than a scan for this port: the invariant is that
 * there are no waits at all, which is both stronger and O(1).
 * api_altblock is not guarded because it clears any waits up front.
 */
#define BLOCKED_TWICE_MSG "already blocked (sys.block from a coroutine? " \
	"use los.thread's park)"

/* block until this port might have room for a message of `need` bytes,
 * the send-side api_block. `need` is optional and defaults to zero,
 * which asks the old question: "is there any room at all".
 *
 * needs only a SEND right: a writer waiting for its reader to catch up
 * has no business holding the receive end.
 *
 * the size argument is not a refinement, it is the difference between
 * parking and spinning. port_push_owned admits a message only if
 * qbytes + len <= MAXQUEUE, so a caller whose message is a large
 * fraction of the queue can be refused while qbytes < MAXQUEUE is still
 * true -- and then this function says "there is room" and returns
 * immediately, the send fails again, and the loop between them burns
 * the proc's whole slice instead of sleeping.
 *
 * that is not hypothetical: two 63KiB pixel bands against a 64KiB
 * MAXQUEUE spun for 33ms per band, which measured as the framebuffer
 * being slow and was really this. small messages never notice, which is
 * why nothing else here had.
 *
 * a `need` larger than MAXQUEUE could never be satisfied, so it returns
 * rather than sleeping forever and lets the send report the failure --
 * the same reason the dead-port case above returns.
 */
/* a park must be issued from the state the kernel resumed.
 *
 * lua_yield unwinds to the resumer of the state it fired in, so a block
 * from a coroutine below p->co lands in whoever resumed THAT -- while
 * this proc is already marked BLOCKED and off the run queue. The kernel
 * believes it is parked and it carries on running, which shows up later
 * as a protocol that stalls somewhere else entirely.
 *
 * Threads are not affected: lib/thread parks them by yielding to
 * thread.run, which does the real block from the top (thread.park's
 * inthread branch). This catches everyone else -- typically a library
 * that owns a coroutine and calls back into code that parks.
 *
 * At entry rather than at the point of descheduling: a call that
 * happens to find its message already there would not park this time,
 * but the code is still wrong and the next call is the one that hangs.
 * Refusing early also keeps the waiter list clean -- a guard after
 * wait_add leaves a waiter registered, and the next block reports
 * "already blocked" instead.
 */
static void
nopark(lua_State *L, struct kproc *p)
{
	if (L != p->co)
		luaL_error(L, "illegal parking: this coroutine is not the "
		    "one the kernel resumed, so a block here would never "
		    "reach it");
}

static int
api_sendblock(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	lua_Integer need = luaL_optinteger(L, 2, 0);	/* raises; before */
	struct right *r;
	enum { OK, BADRIGHT, NEG, DONTSLEEP, TWICE, NOWAIT } rc = OK;

	if (need < 0)
		return luaL_error(L, "negative size");

	/* before the region, because it raises and a raise under the lock
	 * leaves it held. See nopark: at entry is where it belongs anyway.
	 */
	nopark(L, p);

	/* the first entry point narrowed to one bucket, and it qualifies
	 * on both counts: everything below names r->port and nothing
	 * else, and nothing below allocates lua memory -- wait_add's
	 * malloc is the kernel's, over the pmm, with no collector behind
	 * it.
	 *
	 * The right lookup happens before any bucket is taken, because
	 * it is what says which bucket to take. That is sound because a
	 * proc's own right table is not shared: it is read and written
	 * only while that proc runs, and a proc runs on one cpu.
	 * api_anyready reads it with no lock at all on the same grounds.
	 *
	 * The room test and the wait_add are one region, for the reason
	 * api_block's are: a receiver draining the port between them
	 * would wake nobody and leave this proc parked on a port that
	 * has the room it asked for.
	 */
	r = right_get(p, h);
	if (!r) {
		rc = BADRIGHT;
		goto out;
	}
	ipclock_enter_port(r->port);
	if (!SLIST_EMPTY(&p->waiters))
		rc = TWICE;
	else if (r->port->dead)
		rc = DONTSLEEP;		/* never drains; let the send say so */
	else if ((size_t)need > MAXQUEUE)
		rc = DONTSLEEP;		/* can never fit; same */
	else if (r->port->qbytes + (size_t)need <= MAXQUEUE)
		rc = DONTSLEEP;		/* room already */
	else if (!wait_add(p, r->port, 1))
		rc = NOWAIT;
	else {
		proc_block(p);
	}
	ipclock_leave_port(r->port);
out:

	switch (rc) {
	case BADRIGHT:
		return luaL_error(L, "bad right");
	case TWICE:
		return luaL_error(L, BLOCKED_TWICE_MSG);
	case NOWAIT:
		return luaL_error(L, "out of waiters");
	case DONTSLEEP:
		return 0;
	case NEG:
	case OK:
		break;
	}
	return lua_yield(L, 0);
}

/* take the head message off `port`, or null if there is none.
 *
 * The mirror of port_send_from_lua's split, and the same reasoning
 * backwards: detaching the message from the queue is the part that
 * needs the bucket, and turning it into lua values is the part that
 * must not have it. Once detached the message is the caller's alone --
 * no other cpu can reach it -- and the in-flight references it carries
 * keep every port it names alive until msg_dispose.
 */
static struct kmsg *
port_pop(struct kport *port)
{
	struct kmsg *m;

	ipclock_enter_port(port);
	m = port->head;
	if (m) {
		port->head = m->next;
		if (!port->head)
			port->tail = 0;
		port->qbytes -= m->len;
		/* room freed: this is the ordinary backpressure wakeup */
		wake_senders(port);
	}
	ipclock_leave_port(port);
	return m;
}

/* finish with a popped message. Wide only when it carries rights,
 * which is what dropping their in-flight references demands.
 */
static void
msg_dispose(struct kmsg *m)
{
	if (m->nrefs) {
		ipclock_enter();
		msg_free(m);
		ipclock_leave();
	} else {
		msg_free(m);
	}
}

/* push a popped message as ONE lua value, and dispose of it.
 *
 * returns nonzero having pushed nothing: -1 for a message this cannot
 * be, -2 for one it could not receive (a full rights table). A -2 loses
 * any rights the same message already installed.
 */
static int
msg_to_lua(lua_State *L, struct kproc *p, struct kmsg *m)
{
	size_t off = 0;
	/* the reason is kept as deserialize gave it, so popfail can tell a
	 * proc that ran out of rights from a message that would not decode.
	 */
	int rc = deserialize(L, m->data, m->len, &off, p, 0);

	/* receiver now holds its own refs (right_new); drop in-flight */
	msg_dispose(m);
	return rc;
}

/* name a port_pop_to_lua failure: a local limit reached, or a message
 * that could not be decoded.
 */
static int
popfail(lua_State *L, struct kproc *p, int rc)
{
	if (rc == -2)
		return luaL_error(L, "out of rights: %d of %d in use",
		    p->rhigh, MAXRIGHTS);
	return luaL_error(L, "corrupt message");
}

static int
api_tryrecv(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	int empty = 0, rc = 0;

	r = right_get(p, h);
	if (r && r->recv) {
		struct kmsg *m = port_pop(r->port);

		empty = !m;
		if (m) {
			lua_pushboolean(L, 1);
			rc = msg_to_lua(L, p, m);
		}
	}

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (empty) {
		lua_pushboolean(L, 0);
		return 1;
	}
	/* the reason is carried out of the region rather than raised
	 * inside it: popfail raises, and a raise under the lock leaves it
	 * held.
	 */
	if (rc)
		return popfail(L, p, rc);
	return 2;
}

static int
api_block(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	enum { OK, BADRIGHT, HAVEMSG, TWICE, NOWAIT } rc = OK;

	/* before the region, and so before the state change rather than
	 * after the emptiness test. nopark raises, and the region sets
	 * BLOCKED and registers a waiter inside itself -- a guard after
	 * that leaves both behind, which is what nopark exists to avoid.
	 * The cost is that a nested caller whose message is already there
	 * is refused rather than answered; the code is wrong either way
	 * and the next call is the one that hangs.
	 */
	nopark(L, p);

	/* the emptiness test and the wait_add are one region and have to
	 * be: between deciding there is no message and joining the port's
	 * waiter list, a sender on another cpu would push and find nobody
	 * to wake. That is a proc asleep on a port that already has its
	 * message, which is a hang rather than a wrong answer.
	 *
	 * So every reason to refuse is computed in here and reported out
	 * there: luaL_error longjmps, and it must not do so while this is
	 * held.
	 */
	r = right_get(p, h);
	if (!r || !r->recv) {
		rc = BADRIGHT;
		goto out;
	}
	ipclock_enter_port(r->port);
	if (r->port->head)
		rc = HAVEMSG;		/* already there, don't sleep */
	else if (!SLIST_EMPTY(&p->waiters))
		rc = TWICE;
	else if (!wait_add(p, r->port, 0))
		rc = NOWAIT;
	else {
		proc_block(p);
	}
	ipclock_leave_port(r->port);
out:

	switch (rc) {
	case BADRIGHT:
		return luaL_error(L, "bad receive right");
	case HAVEMSG:
		return 0;
	case TWICE:
		return luaL_error(L, BLOCKED_TWICE_MSG);
	case NOWAIT:
		return luaL_error(L, "out of waiters");
	case OK:
		break;
	}
	/* outside the region on purpose: a lock held across a yield is
	 * held until this proc is next resumed, which is a machine-wide
	 * stall for as long as it stays parked.
	 */
	return lua_yield(L, 0);
}

/* sys.call(h, msg, replyh) -> reply | nil, why
 *
 * one kernel entry for the client half of an rpc: send msg on h, then
 * block on replyh for the answer. this is mach_msg's
 * MACH_SEND_MSG|MACH_RCV_MSG, and it exists for the reason mach's does
 * -- a caller making a synchronous call has nothing to do between the
 * two halves, so making it come back out to say so buys nothing and
 * costs a scheduler pass. today that shape is sys.send, return to lua,
 * loop, sys.tryrecv, park: four transitions where this is one.
 *
 * it is also what makes handoff possible at all. the kernel can only
 * switch straight to the receiver if it knows, AT SEND TIME, that the
 * sender is about to sleep on a particular port -- and with the send and
 * the block as separate calls there is no moment at which it knows that.
 * the scheduling change is not here yet; this is the call shape it needs.
 *
 * failures to SEND are reported (nil plus "dead" or "full") rather than
 * raised, exactly as sys.send reports them, because the caller's policy
 * for a full queue is its own. a send that succeeds always waits.
 *
 * a reply port that has hung up reports nil plus "hungup" rather than
 * waiting. this is where thread.recv's rule does not apply: recv cannot
 * treat a quiet port as an ending, because a right that can send is not
 * distinguishable from one that will (see api_hungup). but the port
 * here is a REPLY port, and while a request is in flight it has two
 * rights -- ours and the one that travelled with the message. so a drop
 * back to one with nothing queued says the message was consumed and
 * whoever held the other right is gone, and no answer can ever arrive.
 * lib/mnt.lua has always made that test by hand after each wake; doing
 * it here is what lets it stop.
 *
 * it is not a timeout, and deliberately: a slow server is not a broken
 * one and no deadline tells them apart, but the refcount does. a caller
 * that wants a deadline anyway still composes sys.timer with alt().
 */
static int
call_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	struct right *rr;

	(void)status;

	ipclock_enter();
	rr = right_get(p, (int)ctx);
	/* re-resolved rather than carried across the yield: a handle is an
	 * index into a table this proc can rearrange, and the struct right
	 * behind it may have moved.
	 *
	 * It used to say the proc could not have closed it while parked,
	 * so failing to find it was a bug rather than a race. That was
	 * true of a machine where the only way to reach here was through
	 * this proc's own resume. It is still this proc's own handle
	 * table, so a second cpu cannot close it -- but the port behind
	 * it can be torn down by the last other right going away while we
	 * were parked, so treat the miss as the ordinary outcome it now
	 * is rather than an impossibility.
	 */
	if (!rr || !rr->recv) {
		ipclock_leave();
		return luaL_error(L, "call: reply right went away");
	}
	if (!rr->port->head) {
		/* nobody left who could answer: our right is the last one, so
		 * the one that rode out with the request is gone. checked
		 * before parking again, since the wake that brought us here is
		 * usually the very drop being tested for (port_unref wakes
		 * receivers), and after the queue test so a reply that did
		 * arrive is delivered even when the server answered and died.
		 */
		if (rr->port->nrights <= 1) {
			ipclock_leave();
			lua_pushnil(L);
			lua_pushliteral(L, "hungup");
			return 2;
		}
		/* woken with nothing for us -- another thread in this proc
		 * took the message first. park again. wake_receivers already
		 * dropped our waiter, so this adds a fresh one rather than
		 * leaking the old.
		 */
		if (!wait_add(p, rr->port, 0)) {
			ipclock_leave();
			return luaL_error(L, "out of waiters");
		}
		proc_block(p);
		ipclock_leave();
		return lua_yieldk(L, 0, ctx, call_k);
	}

	/* detach inside the region that established the queue is not
	 * empty, and deserialize outside it -- the message is ours alone
	 * once it is off the queue.
	 */
	struct kmsg *m = port_pop(rr->port);

	ipclock_leave();

	int rc = msg_to_lua(L, p, m);

	/* named out here, because popfail raises */
	if (rc)
		return popfail(L, p, rc);
	return 1;
}

static int
api_call(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer sh = luaL_checkinteger(L, 1);	/* raises; before */
	lua_Integer rh = luaL_checkinteger(L, 3);	/* raises; before */
	struct right *r, *rr;
	int twice;

	luaL_checkany(L, 2);				/* raises; before */

	/* before the region, because it raises. sys.call blocks, so the
	 * same guard applies as to sys.block -- and it is checked before
	 * the send below, so a call that cannot wait also does not deliver
	 * a request whose answer nobody will collect.
	 */
	nopark(L, p);

	ipclock_enter();
	r = right_get(p, sh);
	rr = right_get(p, rh);
	twice = !SLIST_EMPTY(&p->waiters);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "call: bad right");
	if (!rr || !rr->recv)
		return luaL_error(L, "call: bad reply right");
	/* before the send, not after: refusing a call we cannot finish is
	 * better than delivering a request whose answer nobody will collect.
	 *
	 * checked even though call_k takes an already-queued reply without
	 * yielding at all -- a call that happens to work from a coroutine
	 * when the server is same-proc and corrupts the waiter list when it
	 * is not is worse than one that always refuses. los.thread's call()
	 * is the shape for a thread, and picks this only at the top level.
	 */
	if (twice)
		return luaL_error(L, BLOCKED_TWICE_MSG);

	ipclock_enter();
	int rc = port_send_from_lua(L, p, r, 2);

	ipclock_leave();

	if (rc == SEND_UNSERIALIZABLE)
		return luaL_error(L, "unserializable message");
	if (rc == SEND_NOMEM)
		return luaL_error(L, "out of memory queueing message");
	if (rc == SEND_DEAD) {
		lua_pushnil(L);
		lua_pushliteral(L, "dead");
		return 2;
	}
	if (rc == SEND_FULL) {
		lua_pushnil(L);
		lua_pushliteral(L, "full");
		return 2;
	}
	/* the reply may already be queued -- a same-proc service, or one
	 * that ran between our send and here -- in which case call_k takes
	 * it without yielding at all.
	 */
	return call_k(L, LUA_OK, (lua_KContext)rh);
}

/* which entry of the handle table at stack index 1 has a message
 * waiting, or 0 for none. the INDEX rather than the handle, so the
 * caller can find it again in the table it passed.
 *
 * this is advisory and must stay that way. it answers a level question
 * -- "is there something there" -- which is exactly the kind that goes
 * stale the moment a second cpu exists. every caller re-checks with a
 * real sys.tryrecv and parks again if it lost the race, so a wrong
 * answer here costs a wasted wake or a late one and can never lose a
 * message. the mp-clean version of this is an atomic take-from-any (a
 * port set), which replaces it rather than building on it.
 */
/* an alt set may carry send waits as well as receive waits: sends[i] is
 * the size entry i wants room for, and anything else means entry i is
 * an ordinary receive. Kept as a parallel table rather than boxing every
 * entry, so the common all-receive call passes nothing extra and builds
 * no garbage.
 *
 * -1 for "not a send wait", since a send of zero bytes is a real
 * question (is there any room at all).
 */
static lua_Integer
altneed(lua_State *L, int i)
{
	lua_Integer need = -1;

	if (!lua_istable(L, 2))
		return -1;
	lua_rawgeti(L, 2, i);
	if (lua_isinteger(L, -1))
		need = lua_tointeger(L, -1);
	lua_pop(L, 1);
	return need < 0 ? -1 : need;
}

static int
altready(lua_State *L, struct kproc *p)
{
	if (!lua_istable(L, 1))
		return 0;

	int n = (int)luaL_len(L, 1);

	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, (int)lua_tointeger(L, -1));

		lua_pop(L, 1);
		if (!r)
			continue;

		lua_Integer need = altneed(L, i);

		if (need >= 0) {
			/* a send wait is ready when the message would fit
			 * -- or when the port is dead, since then the send
			 * itself is what should report it.
			 */
			if (r->port->dead ||
			    r->port->qbytes + (size_t)need <= MAXQUEUE)
				return i;
		} else if (r->recv && r->port->head) {
			return i;
		}
	}
	return 0;
}

/* sys.hangups() -> a counter that changes whenever any port anywhere
 * loses a reference.
 *
 * a ready-port hint can never name a hangup: the thread that needs to
 * notice its peer is gone has nothing queued, which is the whole point.
 * so los.thread cannot use the hint alone -- it would leave such a
 * thread parked forever. watching this instead costs one integer
 * compare per scheduler pass and wakes everyone only on the rare pass
 * where the answer to sys.hungup could actually have changed.
 *
 * deliberately global rather than per-port: it is a "something may have
 * changed, go look" edge, and the going-and-looking is sys.hungup.
 */
static int
api_hangups(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)hangup_gen);
	return 1;
}

/* sys.anyready() -> bool. does any port this proc can receive on have a
 * message waiting?
 *
 * the question a RUNNABLE proc cannot otherwise ask. port_push wakes
 * whoever is parked on the port, which does nothing for a proc that is
 * in the middle of running -- so a lib/thread proc with one thread that
 * never parks has no event telling it a message arrived for one of its
 * parked siblings, and the message waits for the run queue to drain.
 *
 * this is deliberately coarser than sys.altpoll and much cheaper: no
 * table to build or read, no port set, just a scan of this proc's own
 * rights bounded by the highest it has ever held. it answers "is a
 * sweep worth doing at all", so the scheduler can ask every round and
 * pay for altpoll only when the answer is yes.
 */
static int
api_anyready(lua_State *L)
{
	struct kproc *p = self(L);

	for (int i = 0; i < p->rhigh; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used && r->recv && r->port->head) {
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	lua_pushboolean(L, 0);
	return 1;
}

/* sys.altpoll(set) -> index | nil. altblock's non-blocking half, for a
 * proc that is still runnable and only wants to know whether any of its
 * parked threads could make progress. without it los.thread has to wake
 * every parked thread to have each one find out for itself, which is
 * O(threads) coroutine resumes to deliver one message.
 */
static int
api_altpoll(lua_State *L)
{
	struct kproc *p = self(L);
	int i;

	luaL_checktype(L, 1, LUA_TTABLE);
	i = altready(L, p);
	if (!i)
		return 0;
	lua_pushinteger(L, i);
	return 1;
}

/* the tail of api_altblock, after the proc has been woken. returns the
 * ready index if there is one; returning nothing is legal and means
 * "could not say", which is what the caller assumed before this existed.
 */
static int
altblock_k(lua_State *L, int status, lua_KContext ctx)
{
	int i = altready(L, self(L));

	(void)status;
	(void)ctx;
	if (!i)
		return 0;
	lua_pushinteger(L, i);
	return 1;
}

/* take the first available message from a set of receive rights,
 * without ever having merely looked at one.
 *
 * this is what altready/altpoll should become. peeking answers a level
 * question that goes stale the instant a second cpu exists, and the fix
 * is not a better peek -- it is holding the port across the check and
 * the dequeue, which is just this: block, then take. go's chansend
 * takes c.lock, dequeues a sudog from recvq, copies the value into it
 * and readies that one goroutine; 9front libthread's altexec dequeues a
 * specific waiting Alt and _threadready's its thread. neither ever wakes
 * a waiter to let it look for itself.
 *
 * the two passes below (find, then take) are one critical section: this
 * kernel is cooperative and cannot yield between them. when a lock
 * arrives it goes around both, and nothing else about this changes.
 *
 * returns index, message -- the index into the caller's own table, so
 * it can tell which port answered.
 */
static int
altrecv_take(lua_State *L, struct kproc *p)
{
	int i = altready(L, p);

	if (!i)
		return 0;
	lua_rawgeti(L, 1, i);

	struct right *r = right_get(p, (int)lua_tointeger(L, -1));

	lua_pop(L, 1);
	if (!r || !r->recv || !r->port->head)
		return 0;	/* cannot happen today; see the note above */
	lua_pushinteger(L, i);

	struct kmsg *m = port_pop(r->port);

	if (!m)
		return -1;

	int rc = msg_to_lua(L, p, m);

	/* carried out rather than raised: this runs inside the region and
	 * popfail longjmps. The caller names it once outside, and the
	 * value is popfail's own, so "out of rights" survives the trip.
	 */
	if (rc)
		return rc < -1 ? -2 : -1;
	return 2;
}

/* sys.altrecvnb(set) -> index, msg | nothing. the non-blocking form, for
 * a proc that is still runnable and only wants what is already there.
 */
static int
api_altrecvnb(lua_State *L)
{
	int got;

	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checkstack(L, 3, "altrecvnb");

	ipclock_enter();
	got = altrecv_take(L, self(L));
	ipclock_leave();

	if (got < 0)
		return popfail(L, self(L), got);
	return got;
}

static int
altrecv_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	(void)ctx;
	/* nothing for us after all -- a hangup wake, or another proc took
	 * it. returning nothing is legal and means "go round again".
	 */
	int got;

	luaL_checkstack(L, 3, "altrecv");

	ipclock_enter();
	got = altrecv_take(L, self(L));
	ipclock_leave();

	if (got < 0)
		return popfail(L, self(L), got);
	return got;
}

/* block until any entry of a port set is ready.
 *
 * sys.altblock(set [, sends]) -> index | nothing. An entry is a receive
 * wait unless sends[i] gives a size, in which case it waits for room --
 * so one park can cover both directions, which is what lets a thread
 * scheduler park a thread waiting to send without blocking itself.
 */
static int
api_altblock(lua_State *L)
{
	struct kproc *p = self(L);

	int n;

	nopark(L, p);

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1)
		return luaL_error(L, "altblock: need at least one port");
	luaL_checkstack(L, 2, "altblock");	/* raises; before the region */

	/* the whole scan is one region, and that is the point of this
	 * commit. The loop adds a waiter to each port as it goes, so by
	 * the time it reaches port 5 it is already on port 1's list --
	 * and a sender to port 1 would wake this proc and wait_clear its
	 * waiters, after which the loop carries on, adds more, sets
	 * BLOCKED and yields. The proc then sleeps having already been
	 * woken, with its message sitting in a port it is no longer
	 * waiting on. A hang, not a wrong answer.
	 *
	 * Nothing that raises may run in here, so the handle is read
	 * with lua_tointegerx rather than luaL_checkinteger and a bad
	 * one becomes an outcome reported below. altready's comment
	 * about level questions going stale the moment a second cpu
	 * exists is this, and is now answered by holding the lock across
	 * both passes rather than by asking more carefully.
	 */
	ipclock_enter();
	wait_clear(p);
	for (int i = 1; i <= n; i++) {
		int isnum = 0;
		lua_Integer h;
		struct right *r;

		lua_rawgeti(L, 1, i);
		h = lua_tointegerx(L, -1, &isnum);
		lua_pop(L, 1);
		/* raise-free, so it may run in here: rawgeti and a type
		 * test, nothing that allocates or calls a metamethod.
		 */
		lua_Integer need = altneed(L, i);
		int send = need >= 0;

		if (!isnum) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "altblock: bad receive right");
		}
		r = right_get(p, h);
		/* a send wait needs only a send right, for the same reason
		 * api_sendblock does: a writer waiting on its reader has no
		 * business holding the receive end.
		 */
		if (!r || (!send && !r->recv)) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, send ? "altblock: bad right" :
			    "altblock: bad receive right");
		}
		if (send ? (r->port->dead ||
		    r->port->qbytes + (size_t)need <= MAXQUEUE) :
		    (r->port->head != 0)) {
			wait_clear(p);
			ipclock_leave();
			lua_pushinteger(L, i);
			return 1;	/* already ready, don't sleep */
		}
		/* dedup: the caller may list the same handle more than once,
		 * since alt cases share ports. two waits on one port would
		 * both fire and both be released by wait_clear, so this is
		 * about not consuming the pool rather than correctness.
		 *
		 * on the kind as well as the port: wake_senders and
		 * wake_receivers walk the same list and skip what is not
		 * theirs, so one port waited on both ways needs one of each.
		 */
		int seen = 0;
		struct waiter *w;

		SLIST_FOREACH(w, &p->waiters, pw)
			if (w->port == r->port && w->send == send) {
				seen = 1;
				break;
			}
		if (!seen && !wait_add(p, r->port, send)) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "altblock: out of waiters");
		}
	}
	proc_block(p);
	ipclock_leave();
	return lua_yieldk(L, 0, 0, altblock_k);
}

/* sys.altrecv(set) -> index, msg. blocks, then takes. */
static int
api_altrecv(lua_State *L)
{
	struct kproc *p = self(L);

	int n;

	nopark(L, p);

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1)
		return luaL_error(L, "altrecv: need at least one port");

	luaL_checkstack(L, 3, "altrecv");	/* raises; before the region */

	/* the take and the wait-set build are one region. altrecv_take's
	 * own comment already said the find and the take are one
	 * critical section that this kernel could not yield between, and
	 * that a lock would go around both; it goes around rather more
	 * than that, because a message arriving after the take failed
	 * but during the build is lost the same way altblock's is.
	 */
	ipclock_enter();

	int got = altrecv_take(L, p);

	if (got) {
		ipclock_leave();
		if (got < 0)
			return popfail(L, p, got);
		return got;
	}

	wait_clear(p);
	for (int i = 1; i <= n; i++) {
		int isnum = 0;
		lua_Integer h;
		struct right *r;

		lua_rawgeti(L, 1, i);
		h = lua_tointegerx(L, -1, &isnum);
		lua_pop(L, 1);
		if (!isnum) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "altrecv: bad receive right");
		}
		r = right_get(p, h);
		if (!r || !r->recv) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "altrecv: bad receive right");
		}

		int seen = 0;
		struct waiter *w;

		SLIST_FOREACH(w, &p->waiters, pw)
			if (w->port == r->port) {
				seen = 1;
				break;
			}
		if (!seen && !wait_add(p, r->port, 0)) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "altrecv: out of waiters");
		}
	}
	proc_block(p);
	ipclock_leave();
	return lua_yieldk(L, 0, 0, altrecv_k);
}

static int
api_yield(lua_State *L)
{
	return lua_yield(L, 0);
}

static int
api_newport(lua_State *L)
{
	struct kproc *p = self(L);
	struct kport *port;
	int h = -1;

	/* both allocations inside one region, and the errors raised
	 * outside it: luaL_error longjmps, so nothing that raises may
	 * run while this is held.
	 */
	ipclock_enter();
	port = port_new();
	if (port)
		h = right_new(p, port, 1);
	ipclock_leave();

	if (!port)
		return luaL_error(L, "out of ports");
	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, h);
	return 1;
}

static int proc_new(const char *code, size_t codelen, const char *chunkname,
    int is_file, int reductions, size_t mem_limit, int priv);
static void notify_exit(struct kproc *watcher, int pid, const char *reason,
    int status, const char *exitmsg, int broke);

struct dumpbuf {
	char *data;
	size_t len, cap;
};

static int
dump_writer(lua_State *L, const void *src, size_t sz, void *ud)
{
	struct dumpbuf *b = ud;

	(void)L;
	if (b->len + sz > b->cap) {
		size_t ncap = b->cap ? b->cap : 256;

		while (ncap < b->len + sz)
			ncap *= 2;
		char *nd = realloc(b->data, ncap);

		if (!nd)
			return 1;	/* nonzero aborts lua_dump */
		b->data = nd;
		b->cap = ncap;
	}
	memcpy(b->data + b->len, src, sz);
	b->len += sz;
	return 0;
}

/* sys.spawn(code_or_fn, opts): code_or_fn may be a source string (as
 * before) or an actual lua function value. a function is lua_dump'd
 * to a bytecode buffer here, which crosses into the child exactly
 * like a string would (luaL_loadbuffer auto-detects binary chunks) --
 * still bytes at runtime, just no explicit string.dump() at the call
 * site. only plain lua closures dump (lua_dump rejects C functions);
 * upvalues beyond _ENV don't carry values across -- same isolation
 * limit as passing source text, just easier to trip since a closure
 * makes it easy to accidentally capture an outer local.
 */
/* sys.sendright(h) -> a new handle to the same port, SEND ONLY.
 *
 * mach's shape: a receive right is the authority to hand out send rights.
 * we had the recv flag but no way to derive one from lua, and
 * {__right=h} COPIES the flag -- so handing out a port you created also
 * handed out the ability to receive on it. for a port many clients share
 * that lets any of them take another's requests, or take their own and
 * never answer.
 *
 * api_send ignores recv, so a send right is all a client ever needs.
 */
static int
api_sendright(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer arg = luaL_checkinteger(L, 1);	/* raises; before the lock */
	struct right *r;
	int h = -1;

	ipclock_enter();
	r = right_get(p, arg);
	if (r)
		h = right_new(p, r->port, 0);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "bad right");
	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, h);
	return 1;
}

/* release_inflight for the one caller that is not already holding the
 * lock. api_spawn interleaves five of these with luaL_error, and a
 * region wide enough to cover them all would have to survive a
 * longjmp; one acquisition per call cannot.
 */
static void
release_inflight_locked(const unsigned short *refs, const unsigned char *refrecv,
    int nrefs)
{
	ipclock_enter();
	release_inflight(refs, refrecv, nrefs);
	ipclock_leave();
}

static int
api_spawn(lua_State *L)
{
	struct kproc *p = self(L);
	size_t n;
	const char *code;
	struct dumpbuf buf = { 0 };
	int is_dumped = 0;

	if (lua_isfunction(L, 1)) {
		if (lua_iscfunction(L, 1))
			return luaL_error(L,
			    "spawn: cannot dump a C function");
		lua_pushvalue(L, 1);
		if (lua_dump(L, dump_writer, &buf, 0) != 0) {
			free(buf.data);
			return luaL_error(L,
			    "spawn: could not dump function (odd upvalues?)");
		}
		lua_pop(L, 1);
		code = buf.data;
		n = buf.len;
		is_dumped = 1;
	} else {
		code = luaL_checklstring(L, 1, &n);
	}
	int reductions = 0;
	int trace = 0;
	size_t mem_limit = 0;
	char chunkname[32] = "=spawn";

	if (!lua_isnoneornil(L, 2)) {
		luaL_checktype(L, 2, LUA_TTABLE);
		/* opts.trace: arm the ring before the chunk runs.
		 *
		 * sys.set_trace cannot cover a proc that dies quickly --
		 * spawning and then arming is a race the proc usually
		 * wins, and arming a corpse is too late by definition.
		 * a short-lived proc that faults is exactly the one
		 * worth tracing, so the only place to start is before
		 * its first line.
		 */
		lua_getfield(L, 2, "trace");
		if (!lua_isnil(L, -1))
			trace = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "reductions");
		if (!lua_isnil(L, -1))
			reductions = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "mem");
		if (!lua_isnil(L, -1))
			mem_limit = (size_t)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "name");
		if (!lua_isnil(L, -1))
			snprintf(chunkname, sizeof chunkname, "=%s",
			    luaL_checkstring(L, -1));
		lua_pop(L, 1);
	}

	/* opts.arg: one value handed to the child BEFORE its chunk runs,
	 * arriving as the chunk's `...`.
	 *
	 * a message cannot do this job. the child's first line is typically
	 * require(...), which runs before any recv, so anything the child
	 * needs in order to load code at all -- its namespace -- has to be
	 * there already. that is what fork gives plan 9 for free and what
	 * spawn otherwise cannot express.
	 *
	 * the kernel does not interpret it. it is the ordinary serializer,
	 * so rights travel exactly as they do in a message and the value
	 * is mechanism: "deliver this before the chunk starts". what it
	 * means is entirely lua's business.
	 */
	struct wbuf argw = { 0 };
	int have_arg = 0;

	if (!lua_isnoneornil(L, 2)) {
		lua_getfield(L, 2, "arg");
		if (!lua_isnil(L, -1)) {
			int bad;

			ipclock_enter();
			bad = serialize(L, -1, &argw, p, 0);
			if (bad)
				release_inflight(argw.refs, argw.refrecv,
				    argw.nrefs);
			ipclock_leave();
			if (bad) {
				free(argw.p);
				lua_pop(L, 1);
				return luaL_error(L, "spawn: unserializable arg");
			}
			have_arg = 1;
		}
		lua_pop(L, 1);
	}

	/* sys.spawn can never mint a privileged (cons/wire/power-class)
	 * proc: PRIV_NONE is hardwired here. only the kernel's own boot
	 * sequence (spawn_cons/spawn_wire/spawn_power) sets a real priv
	 * value, never reachable from lua.
	 */
	/* the region ends before the error paths below: they call
	 * release_inflight_locked, which takes this lock itself.
	 */
	ipclock_enter();
	int pid = proc_new(code, n, chunkname, 0, reductions, mem_limit,
	    PRIV_NONE);
	struct kproc *child = pid >= 0 ? find_proc(pid) : 0;

	ipclock_leave();

	if (is_dumped)
		free(buf.data);	/* proc_new/luaL_loadbuffer copies, doesn't keep it */

	if (pid < 0) {
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
		return luaL_error(L, "spawn failed");
	}

	if (!child) {
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
		return luaL_error(L, "spawn: child vanished");
	}
	/* before the child has run a line, which is the whole point of
	 * asking for it here. a failure to allocate the ring is not a
	 * failure to spawn: the proc is fine, it is only untraced.
	 */
	if (trace > 0) {
		if (trace > TRACEMAX)
			trace = TRACEMAX;
		trace_arm(child, trace);
	}

	/* push the arg onto the child's stack, above the loaded chunk, so
	 * the first resume passes it as `...`.
	 */
	if (have_arg) {
		size_t off = 0;
		int bad;

		ipclock_enter();
		bad = deserialize(child->co, argw.p, argw.len, &off, child, 0);
		ipclock_leave();
		if (bad) {
			/* a partial deserialize may have left values on co's
			 * stack under the chunk's feet, and rights already
			 * minted into the child. the proc is unusable; kill
			 * it rather than start it half-built.
			 */
			release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
			free(argw.p);
			proc_kill(child, "spawn: could not deliver arg");
			return luaL_error(L, "spawn: could not deliver arg");
		}
		child->nargs = 1;
		/* the in-flight ref taken by serialize; the child now holds
		 * its own from right_new, exactly as a delivered message
		 * releases its refs once received.
		 */
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
	}
	/* hand parent a send right on the child's self port */
	ipclock_enter();
	int h = right_new(p, child->rights[0].port, 0);

	ipclock_leave();

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, pid);
	lua_pushinteger(L, h);
	return 2;
}

/* watch a proc: when it dies, {exit=pid, normal=, reason=?} arrives on
 * our self port. watching a dead/unknown pid delivers noproc at once.
 */
static int
api_monitor(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc(pid);

	/* a corpse is not monitorable: its death notification has already
	 * gone out, and it will never die a second time. treating BROKE as
	 * absent here is what keeps "monitor something already gone" an
	 * immediate noproc rather than a wait for an event in the past.
	 */
	if (target && target->status == BROKE)
		target = 0;
	if (!target) {
		ipclock_enter();
		notify_exit(p, pid, "noproc", -1, 0, 0);
		ipclock_leave();
		lua_pushboolean(L, 1);
		return 1;
	}
	if (target == p)
		return luaL_error(L, "cannot monitor self");
	for (int i = 0; i < target->nwatch; i++)
		if (target->watchers[i] == p->id) {
			lua_pushboolean(L, 1);
			return 1;	/* already watching */
		}
	if (target->nwatch >= MAXWATCH)
		return luaL_error(L, "too many watchers");
	target->watchers[target->nwatch++] = p->id;
	lua_pushboolean(L, 1);
	return 1;
}

/* explicitly drop a right. handle 0 (self port) is not closable. */
static int
api_close(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before the lock */
	struct right *r;

	ipclock_enter();
	r = right_get(p, h);
	if (r && h != 0)
		right_drop(r);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "bad right");
	if (h == 0)
		return luaL_error(L, "cannot close self port");
	if ((int)h < p->rhint)
		p->rhint = (int)h;	/* reuse the slot we just freed */
	return 0;
}

static void preempt_hook(lua_State *L, lua_Debug *ar);
static void proc_armall(struct kproc *p, int count);
/* the los.sys table, defined below. Forward-declared because
 * api_syscalls reads its names and kapi lists api_syscalls, which is a
 * circle that has to be broken somewhere.
 */
static const luaL_Reg kapi[];
static void trace_put(struct kproc *p, struct ktrace *t, int line, int src,
    int co);
static void trace_mark(struct kproc *p, const char *what);

/* memory accounting: meminfo([pid]) -> used, peak, limit */
static int
api_meminfo(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	/* per proc, and only per proc: what the heap holds is a property of
	 * the machine now that every state shares one, so it is reported by
	 * sys.stats instead. Reporting it here would attribute the whole
	 * machine's heap to whichever proc was asked about.
	 */
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	return 3;
}

static int
api_stats(lua_State *L)
{
	int nports = 0, nprocs = 0, nbroke = 0;

	for (int i = 0; i < porthigh; i++)
		if (portv[i])
			nports++;
	/* corpses are counted separately rather than as procs. they are
	 * listed by sys.procs, because a corpse you cannot find is a
	 * corpse you cannot inspect, but they hold no rights and will
	 * never run -- counting them here would make "procs" disagree
	 * with nlive and read as a leak after every crash.
	 */
	for (int i = 0; i < prochigh; i++)
		if (procv[i] && procv[i]->status == BROKE)
			nbroke++;
		else if (procv[i] && procv[i]->status != DEAD)
			nprocs++;
	lua_createtable(L, 0, 3);
	lua_pushinteger(L, nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, nprocs);
	lua_setfield(L, -2, "procs");
	lua_pushinteger(L, nbroke);
	lua_setfield(L, -2, "broke");
	unsigned long long tidle = 0, tlaps = 0, tdisp = 0;

	for (unsigned i = 0; cpu_at(i); i++) {
		tidle += cpu_at(i)->nidle;
		tlaps += cpu_at(i)->nlaps;
		tdisp += cpu_at(i)->ndispatch;
	}
	lua_pushinteger(L, (lua_Integer)tidle);
	lua_setfield(L, -2, "idles");
	lua_pushinteger(L, rights_high);
	lua_setfield(L, -2, "rightshigh");
	lua_pushinteger(L, (lua_Integer)tlaps);
	lua_setfield(L, -2, "laps");
	lua_pushinteger(L, (lua_Integer)tdisp);
	lua_setfield(L, -2, "dispatches");


	/* the firmware's view: what the machine has, and what is left. this
	 * is the ceiling the other figures sit under, since a proc is a
	 * lua_State drawn from the same pool.
	 */
	unsigned long long mtotal = 0, mavail = 0;

	platform_meminfo(&mtotal, &mavail);
	lua_pushinteger(L, (lua_Integer)mtotal);
	lua_setfield(L, -2, "memtotal");
	lua_pushinteger(L, (lua_Integer)mavail);
	lua_setfield(L, -2, "memavail");

	/* the c heap, i.e. everything not on a per-proc lua heap: port
	 * messages, net tokens and payload copies, loadfile buffers.
	 * sys.meminfo(pid) covers the lua side.
	 */
	size_t hlive, hpeak;
	unsigned long hblocks, htotal;

	malloc_stats(&hlive, &hpeak, &hblocks, &htotal);
	lua_pushinteger(L, (lua_Integer)hlive);
	lua_setfield(L, -2, "heap_used");
	lua_pushinteger(L, (lua_Integer)hpeak);
	lua_setfield(L, -2, "heap_peak");
	lua_pushinteger(L, (lua_Integer)hblocks);
	lua_setfield(L, -2, "heap_blocks");
	lua_pushinteger(L, (lua_Integer)htotal);
	lua_setfield(L, -2, "heap_total_allocs");

	/* the lua heaps, summed: there is one per proc now, and what the
	 * machine wants to know is still the total. live is what the
	 * states asked for; mapped is what the machine holds to serve it,
	 * and the gap is what bounds how many procs fit.
	 *
	 * Note heap_used above counts these chunks as ordinary C
	 * allocations, since that is what they are -- so the two are not
	 * additive.
	 */
	struct luaheap_stats hs = { 0 }, one;

	/* one heap answers for the whole machine when there is one; the
	 * per-proc loop would count it once per proc.
	 */
	if (shared_heap) {
		luaheap_stats(shared_heap, &hs);
	} else {
		for (int i = 0; i < prochigh; i++) {
			if (!procv[i] || !procv[i]->heap)
				continue;
			luaheap_stats(procv[i]->heap, &one);
			hs.live += one.live;
			hs.peak += one.peak;
			hs.mapped += one.mapped;
			hs.waste += one.waste;
			hs.rounding += one.rounding;
			hs.headers += one.headers;
			hs.unused += one.unused;
			hs.chunks += one.chunks;
			hs.larges += one.larges;
		}
	}
	lua_pushinteger(L, (lua_Integer)hs.live);
	lua_setfield(L, -2, "lua_live");
	lua_pushinteger(L, (lua_Integer)hs.mapped);
	lua_setfield(L, -2, "lua_mapped");
	lua_pushinteger(L, (lua_Integer)hs.waste);
	lua_setfield(L, -2, "lua_waste");
	/* and where that waste is, because the three answer different
	 * questions: rounding is the size classes being wrong for this
	 * target, unused is the chunk size being wrong for this working
	 * set, and headers is neither. Tuning one when the cost is in
	 * another is the mistake this exists to prevent.
	 */
	lua_pushinteger(L, (lua_Integer)hs.rounding);
	lua_setfield(L, -2, "lua_rounding");
	lua_pushinteger(L, (lua_Integer)hs.headers);
	lua_setfield(L, -2, "lua_headers");
	lua_pushinteger(L, (lua_Integer)hs.unused);
	lua_setfield(L, -2, "lua_unused");
	/* the tsc calibration, so a benchmark can time with sys.ticks()
	 * -- sub-nanosecond -- and still report real units. uptime_ms has
	 * 1ms granularity, which is useless over a 20ms measurement.
	 */
	lua_pushinteger(L, (lua_Integer)cyc_per_ms);
	lua_setfield(L, -2, "cycles_per_ms");
	lua_pushinteger(L, default_reductions);
	lua_setfield(L, -2, "reductions");
	/* which src/<arch> this image was built from, so nothing in lua
	 * has to hardcode the answer (init.lua's /uname did).
	 */
	lua_pushstring(L, platform_arch());
	lua_setfield(L, -2, "arch");
	/* how many cpus came up. This is the only way to ask from
	 * inside: an AP that failed to start leaves nothing behind for
	 * a proc to notice, so the count has to be reported rather than
	 * inferred.
	 */
	lua_pushinteger(L, (lua_Integer)platform_ncpu());
	lua_setfield(L, -2, "cpus");
	/* and what each of them is doing. A count alone cannot tell a
	 * machine dispatching on two cpus from one that started a second
	 * cpu and left it parked -- which is exactly what this branch
	 * did for several commits, with a passing test for it.
	 */
	lua_newtable(L);
	for (unsigned i = 0; cpu_at(i); i++) {
		struct cpu *c = cpu_at(i);

		lua_createtable(L, 0, 5);
		lua_pushinteger(L, (lua_Integer)c->apicid);
		lua_setfield(L, -2, "apicid");
		lua_pushboolean(L, c->dispatching);
		lua_setfield(L, -2, "dispatching");
		lua_pushinteger(L, (lua_Integer)c->nlaps);
		lua_setfield(L, -2, "laps");
		lua_pushinteger(L, (lua_Integer)c->ndispatch);
		lua_setfield(L, -2, "dispatched");
		lua_pushinteger(L, (lua_Integer)c->nidle);
		lua_setfield(L, -2, "idles");
		lua_rawseti(L, -2, (lua_Integer)i + 1);
	}
	lua_setfield(L, -2, "cpu");
	/* the two locks kernel.c owns, so contention is a number rather
	 * than an argument. `spin` is cycles a cpu spent waiting, and it
	 * is the figure that says whether splitting a lock would buy
	 * anything: an uncontended lock has nothing to give back.
	 */
	lua_newtable(L);
	{
		/* ipc is the bucket array summed. A per-bucket breakdown
		 * would say something else worth knowing -- whether the
		 * hash spreads the ports evenly -- but the totals are
		 * what compares against the single-lock measurement, and
		 * that comparison is what this exists for.
		 */
		unsigned long long nlock = 0, ncontend = 0, spin = 0;
		unsigned long long held = 0;

		for (unsigned i = 0; i < NIPCLOCK; i++) {
			nlock += ipcbuckets[i].lk.nlock;
			ncontend += ipcbuckets[i].lk.ncontend;
			spin += ipcbuckets[i].lk.spin;
			held += ipcbuckets[i].held;
		}

		lua_createtable(L, 0, 4);
		lua_pushinteger(L, (lua_Integer)nlock);
		lua_setfield(L, -2, "locks");
		lua_pushinteger(L, (lua_Integer)ncontend);
		lua_setfield(L, -2, "contended");
		lua_pushinteger(L, (lua_Integer)spin);
		lua_setfield(L, -2, "spin");
		lua_pushinteger(L, (lua_Integer)held);
		lua_setfield(L, -2, "held");
		lua_setfield(L, -2, "ipc");

		lua_createtable(L, 0, 3);
		lua_pushinteger(L, (lua_Integer)schedlock.nlock);
		lua_setfield(L, -2, "locks");
		lua_pushinteger(L, (lua_Integer)schedlock.ncontend);
		lua_setfield(L, -2, "contended");
		lua_pushinteger(L, (lua_Integer)schedlock.spin);
		lua_setfield(L, -2, "spin");
		lua_setfield(L, -2, "sched");
	}
	lua_setfield(L, -2, "lock");
	return 1;
}

static int
api_self(lua_State *L)
{
	lua_pushinteger(L, self(L)->id);
	return 1;
}

static int
api_procs(lua_State *L)
{
	lua_newtable(L);
	for (int i = 0, n = 1; i < MAXPROCS; i++)
		if (procv[i] && procv[i]->status != DEAD) {
			lua_pushinteger(L, procv[i]->id);
			lua_rawseti(L, -2, n++);
		}
	return 1;
}

/* which proc holds the receive right to a port, or -1. Not 0: pid 0 is
 * the console, a real proc that really does own ports, and using it as
 * the "nobody" sentinel reported every one of them as unowned.
 *
 * Answered by
 * looking rather than by a field on the port, because a receive right
 * moves: the holder is wherever it was last sent, and a field would be
 * one more thing to keep true on every transfer for the sake of a call
 * nobody makes in a hot loop.
 */
static int
port_owner(const struct kport *port)
{
	for (int i = 0; i < prochigh; i++) {
		struct kproc *p = procv[i];

		if (!p || p->status == DEAD)
			continue;
		for (int h = 0; h < MAXRIGHTS; h++) {
			struct right *r = right_get(p, h);

			if (r && r->recv && r->port == port)
				return p->id;
		}
	}
	return -1;
}

/* sys.ports(): one row per live port, for an ss-shaped view of where
 * messages are going and what is being refused.
 *
 * Ungated, like sys.procs(): a port index grants nothing without a
 * right to it, so this shows the shape of the system without handing
 * over any part of it.
 */
static int
api_ports(lua_State *L)
{
	lua_newtable(L);
	for (int i = 0, n = 1; i < porthigh; i++) {
		struct kport *port = portv[i];

		if (!port)
			continue;

		lua_createtable(L, 0, 9);
		lua_pushinteger(L, port->idx);
		lua_setfield(L, -2, "port");
		/* absent rather than a sentinel when no proc holds the
		 * receive right, so no valid pid can be mistaken for one.
		 */
		int owner = port_owner(port);

		if (owner >= 0) {
			lua_pushinteger(L, owner);
			lua_setfield(L, -2, "owner");
		}
		lua_pushinteger(L, port->nrights);
		lua_setfield(L, -2, "rights");
		lua_pushinteger(L, port->nrecv);
		lua_setfield(L, -2, "recv");
		lua_pushboolean(L, port->dead);
		lua_setfield(L, -2, "dead");
		lua_pushinteger(L, (lua_Integer)port->qbytes);
		lua_setfield(L, -2, "qbytes");
		lua_pushinteger(L, (lua_Integer)port->qpeak);
		lua_setfield(L, -2, "qpeak");
		lua_pushinteger(L, (lua_Integer)port->nsent);
		lua_setfield(L, -2, "sent");
		lua_pushinteger(L, (lua_Integer)port->ndrop_full);
		lua_setfield(L, -2, "dropfull");
		lua_pushinteger(L, (lua_Integer)port->ndrop_dead);
		lua_setfield(L, -2, "dropdead");
		lua_rawseti(L, -2, n++);
	}
	return 1;
}

static int
api_procname(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	lua_pushstring(L, p->name);
	return 1;
}

/* sys.wchan(pid): a unix-"wchan"-style debugging hint -- what a
 * blocked proc is actually waiting on, exposed as the receive port's
 * index in the global ports[] table (the same number serialize()
 * already uses to tag right transfers, not a friendly name, but
 * stable and unique -- good enough for ps/debugging). "ready"/"dead"
 * for the other two states; "alt[...]" lists every port a
 * thread.alt() is waiting across.
 */
/* pushes the wchan string for p and returns 1, so api_wchan and
 * api_pidstat report the same thing by construction rather than by two
 * copies of this agreeing.
 */
static int push_wchan(lua_State *L, struct kproc *p);

static int
api_wchan(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	return push_wchan(L, p);
}

static int
push_wchan(lua_State *L, struct kproc *p)
{
	switch (p->status) {
	case DEAD:
		lua_pushliteral(L, "dead");
		return 1;
	case BROKE:
		lua_pushliteral(L, "broke");
		return 1;
	case READY:
		lua_pushliteral(L, "ready");
		return 1;
	case BLOCKED: {
		struct waiter *only = SLIST_FIRST(&p->waiters);

		if (only && !only->send && !SLIST_NEXT(only, pw)) {
			lua_pushfstring(L, "port#%d",
			    (int)only->port->idx);
			return 1;
		}
	}
		/* distinguished from a receive wait on purpose: "why is
		 * this proc stuck" has a different answer for a reader
		 * with no data and a writer with no room, and ps is where
		 * you go to find out.
		 */
		struct waiter *w = SLIST_FIRST(&p->waiters);

		if (w && w->send) {
			lua_pushfstring(L, "sendq#%d",
			    (int)w->port->idx);
			return 1;
		}
		if (w) {
			luaL_Buffer b;
			int first = 1;

			luaL_buffinit(L, &b);
			luaL_addstring(&b, "alt[");
			SLIST_FOREACH(w, &p->waiters, pw) {
				char tmp[16];

				snprintf(tmp, sizeof tmp, "%s%d",
				    first ? "" : ",",
				    (int)w->port->idx);
				first = 0;
				luaL_addstring(&b, tmp);
			}
			luaL_addstring(&b, "]");
			luaL_pushresult(&b);
			return 1;
		}
		lua_pushliteral(L, "blocked");
		return 1;
	}
	lua_pushliteral(L, "?");
	return 1;
}

/* ---- holding a proc still while another one reads it ----
 *
 * Reading another proc's stack was once safe for free: the machine was
 * cooperative and single-threaded, so every proc but the caller was
 * suspended between resumes and there was no moment at which a stack
 * was half-built. On more than one cpu that is simply false -- the
 * target can be running, pushing and popping frames, while the reader
 * walks it.
 *
 * Refusing to read a running proc would be easy and useless: a spinning
 * proc is running by definition, and it is the one you most want to
 * sample. So the target is held still instead.
 *
 * Freeze first, then wait. Setting frozen stops dispatch from resuming
 * it again; waiting for it to stop being some cpu's `current` is what
 * makes the stack quiet. In that order there is no window -- the other
 * order lets it be re-dispatched between the check and the walk.
 *
 * The wait ends even for a proc that never yields, because the preempt
 * hook cuts one every quantum, so it stops being current within a
 * quantum whatever it is doing.
 *
 * And the wait yields rather than spins, which is what keeps two
 * readers from deadlocking on each other: a reader that yields is no
 * longer running, so the proc it is waiting for is free to stop.
 */
/* one lock, and it is the scheduler's: that is where a proc is taken
 * and given back, and the one make_ready already takes to decide the
 * same thing.
 *
 * The proc is asked, not the cpus. Asking every cpu whether it is
 * running p means asking `cpu_at(i)` for i below `platform_ncpu()`, and
 * that count trails reality during boot -- startap raises it only once
 * an AP has come up, so an AP that is already dispatching is not in it
 * yet. A scan misses that cpu. p->oncpu cannot: it is written by
 * whichever cpu has p in hand, counted or not.
 *
 * p->home says where it last ran, which is a report and not an answer.
 */
static int
proc_running(struct kproc *p)
{
	return p->oncpu != 0;
}

/* returns whether the target is running right now; frozen is raised
 * either way, so the caller may wait and ask again without a window in
 * between.
 */
static int
proc_freeze(struct kproc *p)
{
	int running;

	lock(&schedlock);
	p->frozen++;
	running = proc_running(p);
	unlock(&schedlock);
	return running;
}

static void
proc_thaw(struct kproc *p)
{
	lock(&schedlock);
	if (p->frozen > 0)
		p->frozen--;
	unlock(&schedlock);
}

/* the same question, asked again after a yield, when the freeze is
 * already ours.
 */
static int
proc_still_running(struct kproc *p)
{
	int running;

	lock(&schedlock);
	running = proc_running(p);
	unlock(&schedlock);
	return running;
}

/* ---- the shape every cross-proc syscall takes ----
 *
 * Reading or changing another proc needs it held still, and that is not
 * particular to stacks: a trace ring is walked while the target writes
 * it, set_trace frees a ring the target may be mid-write into, and
 * anything that lands here later will have the same problem. So the
 * waiting is written once.
 *
 * What cannot be shared is the yield itself -- lua_yieldk names the
 * continuation, and each syscall's is its own. So this returns which of
 * the three situations the caller is in and lets it yield by name:
 *
 *	static int api_x_k(lua_State *L, int status, lua_KContext ctx)
 *	{
 *		struct kproc *p;
 *
 *		switch (proc_hold(L, 1, &p, ctx)) {
 *		case HOLD_WAIT:	return lua_yieldk(L, 0, 1, api_x_k);
 *		case HOLD_GONE:	return luaL_error(L, "no such proc");
 *		case HOLD_SELF:	... do it, nothing to hold ...
 *		case HOLD_HELD:	... do it, then proc_thaw(p) ...
 *		}
 *	}
 *
 * A body that can RAISE must run protected, because a raise past the
 * thaw leaves the target frozen -- a proc that never runs again, which
 * is a worse bug than the race being fixed. Anything building a table
 * in the caller's state can raise: it allocates, and the caller has a
 * memory limit.
 */
enum { HOLD_SELF, HOLD_HELD, HOLD_WAIT, HOLD_GONE };

static int
proc_hold(lua_State *L, int argn, struct kproc **out, lua_KContext ctx)
{
	struct kproc *me = self(L);
	struct kproc *p = me;

	if (!lua_isnoneornil(L, argn)) {
		p = find_proc((int)luaL_checkinteger(L, argn));
		if (!p)
			return HOLD_GONE;
	}
	*out = p;
	if (p == me)
		return HOLD_SELF;	/* the one proc that cannot move */

	/* frozen on the first pass and left frozen across every yield, so
	 * there is no window in which it could be dispatched again
	 * between the wait and the read. ctx says it is already ours.
	 */
	if (ctx == 0) {
		if (proc_freeze(p))
			return HOLD_WAIT;
	} else if (proc_still_running(p)) {
		return HOLD_WAIT;
	}
	return HOLD_HELD;
}

/* sys.stack(pid) -> { {source=, line=, name=, what=}, ... }
 *
 * a traceback of another proc, held still first: see proc_freeze above.
 * lua_getstack/lua_getinfo on a suspended coroutine are ordinary
 * read-only debug API, and once the target cannot be resumed they are
 * as quiet as they were when one cpu made that true for free.
 *
 * two rules make it safe:
 *
 * 1. Nothing is pushed onto the target's stack. the "Sln" info string is
 *    push-free (unlike "f" or "L"), and every result table is built on
 *    the caller's state. leave the target unbalanced and it resumes into
 *    garbage.
 * 2. No lua code runs in the target. luaL_traceback would allocate in
 *    the target's heap, charged to its mem_limit -- exactly why
 *    kernel_run skips it on LUA_ERRMEM -- and stringifying a value could
 *    invoke __tostring, which in this system has been known to power the
 *    machine off. so this reports structure only: source, line, function
 *    name. locals are values rather than structure and are deliberately
 *    not here; when they land they want a capability, unlike this.
 *
 * ambient for the same reason sys.procs/name/wchan are: it says what the
 * machine is doing, not what any proc's data is, and the threat model is
 * buggy lua rather than hostile users.
 */
#define MAXFRAMES	64

/* the walk, as a lua function so it can be called protected: it
 * allocates in the caller's state to build the result, so it can raise
 * on a caller at its memory limit -- and a raise that escaped would
 * leave the target frozen, which is a proc that never runs again.
 */
static int
stack_walk(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);

	/* src/debug.c: every coroutine, not just the proc's own. A proc
	 * built on lib/thread keeps its threads as coroutines inside its
	 * state, and walking only p->co reported the scheduler -- the same
	 * three frames for an idle proc and a deadlocked one.
	 */
	debug_push_stacks(L, p->L, p->co);
	return 1;
}

static int api_stack_k(lua_State *L, int status, lua_KContext ctx);

static int
api_stack(lua_State *L)
{
	return api_stack_k(L, LUA_OK, 0);
}

static int
api_stack_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_stack_k);
	case HOLD_SELF:
		debug_push_stacks(L, p->L, p->co);
		return 1;
	}

	/* protected: the walk builds its result in this proc's state, so
	 * it allocates, so it can raise -- and a raise past the thaw would
	 * leave the target frozen for good.
	 */
	lua_pushcfunction(L, stack_walk);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* (re)size a proc's ring and make the mask match. n == 0 frees it.
 *
 * shared by sys.set_trace and spawn's opts.trace, so there is one place
 * that knows the flag has to be set BEFORE proc_rearm -- proc_hookmask
 * reads it, and proc_rearm is what makes the mask real on every
 * coroutine of the proc.
 */
static int
trace_arm(struct kproc *p, int n)
{
	if (p->trace) {
		free(p->trace->ent);
		free(p->trace);
		p->trace = 0;
	}
	if (n > 0) {
		struct ktrace *t = malloc(sizeof *t);

		if (!t)
			return -1;
		memset(t, 0, sizeof *t);
		t->ent = malloc((size_t)n * sizeof *t->ent);
		if (!t->ent) {
			free(t);
			return -1;
		}
		t->cap = (unsigned int)n;
		t->lastid = -1;
		p->trace = t;
	}
	proc_rearm(p);
	return 0;
}

/* sys.set_trace(pid, entries): record the last N lines this proc runs.
 * entries = 0 turns it off and frees the ring.
 *
 * this is the expensive one, and says so. a line hook fires per line
 * instead of every REDUCTIONS instructions: measured on a tight
 * arithmetic loop, 3ms untraced against 14ms traced, so 4.7x. that is
 * the whole cost model -- it buys a record of how a proc reached its
 * fault, which a stack cannot give because a stack shows only the calls
 * still open.
 *
 * concretely: a proc recursing through outer -> inner until it raises
 * has a traceback of "dier:8: in function <dier:7> | (...tail calls...)
 * | dier:11: in main chunk". the recursion is not in it, collapsed into
 * one tail-call marker, because those frames are exactly the ones no
 * longer open. the ring holds every iteration and the line the last one
 * diverged on.
 *
 * an untraced proc pays nothing: the mask carries LUA_MASKLINE only
 * while a ring exists, so the line hook is absent rather than idle.
 *
 * ambient, like sys.stack and sys.reap, and this is the weakest of the
 * three claims: slowing a proc down is a real effect on it, unlike
 * reading it. what makes it acceptable is the same threat model the
 * rest of this file runs on -- buggy lua, not hostile procs -- plus the
 * fact that anything wanting to wreck a neighbour's timing can already
 * do it by spinning. it is a tool for the person at the console.
 */
/* sys.set_torture(pid, on) -- see preempt_hook. A debugging knob that
 * costs the machine a real guarantee while it is on, so it is PRIV_BOOT
 * only: a boot payload (which is what every test is) may ask for it,
 * and nothing else can.
 *
 * Arming is by inheritance as much as by the sweep below:
 * lua_newthread copies hook, mask and count from the state that
 * created it, so a thread spawned after this returns is born tortured.
 * Turn it on BEFORE spawning the threads that are meant to be cut.
 */
static int
api_set_torture(lua_State *L)
{
	struct kproc *p = self(L);
	int arg = 1;

	if (lua_gettop(L) > 1) {
		arg = 2;
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	if (!kernel_current_is_boot())
		return luaL_error(L, "no permission to torture a proc");
	if (!p->L)
		return luaL_error(L, "proc %d has no state", p->id);

	p->torture = lua_toboolean(L, arg);
	/* every instruction, or back to the calibrated budget */
	proc_armall(p, p->torture ? 1 : p->reductions);
	lua_pushboolean(L, 1);
	return 1;
}

static int set_trace_k(lua_State *L, int status, lua_KContext ctx);

static int
api_set_trace(lua_State *L)
{
	return set_trace_k(L, LUA_OK, 0);
}

static int
set_trace_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	int arg = 1;
	lua_Integer n;

	(void)status;

	if (lua_gettop(L) > 1 || (lua_gettop(L) == 1 && lua_isnoneornil(L, 1)))
		arg = 2;
	if (arg == 2 && !lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	n = luaL_checkinteger(L, arg);
	if (n < 0)
		return luaL_error(L, "trace size must not be negative");
	if (n > TRACEMAX)
		n = TRACEMAX;
	if (!p->L)
		return luaL_error(L, "proc %d has no state", p->id);
	/* a trace has to be armed before the death it is meant to
	 * explain. arming a corpse can only ever produce an empty ring,
	 * which reads as "this proc ran no lines" rather than "you are
	 * too late", so it is refused. for a proc too short-lived to
	 * catch, spawn's opts.trace is the way in.
	 */
	if (p->status == BROKE && n > 0)
		return luaL_error(L,
		    "proc %d is broke; trace before it dies, or spawn "
		    "with opts.trace", p->id);

	/* held for the arm itself, and only for that. This is the one
	 * cross-proc call that writes: trace_arm frees and reallocates a
	 * ring the target's line hook is putting entries into, so doing it
	 * to a running proc frees memory out from under a writer.
	 *
	 * Everything above that can raise has already run, so the freeze
	 * spans nothing that could longjmp past the thaw. trace_arm itself
	 * only allocates C memory and reports failure by return.
	 */
	if (p != self(L)) {
		if (ctx == 0) {
			if (proc_freeze(p))
				return lua_yieldk(L, 0, 1, set_trace_k);
		} else if (proc_still_running(p)) {
			return lua_yieldk(L, 0, 1, set_trace_k);
		}
	}

	int armed = trace_arm(p, (int)n);

	if (p != self(L))
		proc_thaw(p);
	if (armed != 0)
		return luaL_error(L, "out of memory");
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.trace([pid]) -> { {source=, line=, thread=}, ... }, oldest first.
 *
 * readable on a corpse, which is the point: the ring is freed with the
 * state, so a broke proc still says how it got where it stopped.
 *
 * Held still first, like sys.stack and for the same reason: a running
 * target writes this ring on every line it executes, so walking it
 * unheld reads entries being overwritten underneath.
 */
static int trace_read_k(lua_State *L, int status, lua_KContext ctx);

static int
api_trace(lua_State *L)
{
	return trace_read_k(L, LUA_OK, 0);
}

static int
trace_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct ktrace *t;
	unsigned int n, start;

	t = p->trace;
	if (!t || !t->cap) {
		lua_newtable(L);
		return 1;
	}
	n = t->n < t->cap ? t->n : t->cap;
	start = t->n - n;

	lua_createtable(L, (int)n, 0);
	for (unsigned int i = 0; i < n; i++) {
		struct tracent *e = &t->ent[(start + i) % t->cap];

		lua_createtable(L, 0, 5);
		lua_pushstring(L, e->src < t->nname ? t->name[e->src] : "?");
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, e->line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, e->co);
		lua_setfield(L, -2, "thread");
		/* cycles this line cost, and cycles the proc was not running
		 * after it. See struct tracent on why both.
		 */
		lua_pushinteger(L, e->cpu);
		lua_setfield(L, -2, "cpu");
		lua_pushinteger(L, e->wall);
		lua_setfield(L, -2, "wall");
		lua_rawseti(L, -2, (int)i + 1);
	}
	return 1;
}

static int
trace_read_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, trace_read_k);
	case HOLD_SELF:
		lua_pushlightuserdata(L, p);
		lua_replace(L, 1);
		return trace_body(L);
	}

	lua_pushcfunction(L, trace_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* sys.tracehist(pid): the ring, aggregated by source and line.
 *
 * Every caller that wanted a profile was writing the same fifteen lines
 * of Lua -- count by source:line, sort, count again by file -- and the
 * first time anyone did it, it found a task rebuilding a kernel timer
 * on every message. That is worth having built in.
 *
 * It is computed here rather than in the caller for the reason
 * src/debug.c allocates nothing in its target: handing over a
 * 4096-entry table charges the reader's mem_limit for the act of
 * reading, and the ring is bigger than anything debug.c builds.
 *
 * Keyed on source and line, NOT on thread. What a line costs is a
 * property of the line; which coroutine ran it is a different question
 * and the raw ring still answers it. Keying on both would multiply the
 * rows of a lib/thread proc, where the same scheduler lines run in
 * every thread, and bury the total that is usually wanted.
 *
 * Sorted by cpu, so the answer to "where does the time go" is the top
 * of the list. With no timestamps in play that degenerates to sorting
 * by count, which is the older question and still a useful one.
 */
/* The fallback table, used only if the exact one cannot be allocated.
 * See the allocation below for why exact matters.
 */
#define HISTMAX 256

struct histrow {
	int line;
	unsigned short src;
	unsigned int count;
	unsigned long long cpu;
	unsigned long long wall;
};

static int
tracehist_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct ktrace *t;
	struct histrow *row;
	int cap, nrow = 0, last = -1;
	unsigned int n, start, dropped = 0;

	t = p->trace;
	if (!t || !t->cap) {
		lua_newtable(L);
		return 1;
	}
	n = t->n < t->cap ? t->n : t->cap;
	start = t->n - n;

	/* Sized to the ring, so every distinct line gets a row and the
	 * result is the hottest lines rather than the earliest ones.
	 *
	 * A fixed table cannot do that. Aggregation meets keys in the order
	 * they occur, so a table that fills simply stops admitting new
	 * ones -- and the lines it then fails to report are not the cold
	 * ones, they are whichever happened to appear late. A histogram
	 * that quietly does that is worse than no histogram, because it
	 * looks like an answer. Measured before this: 256 rows kept, 303
	 * entries dropped, on a trace of one task.
	 *
	 * Allocated per call and freed below, so tracing costs what it
	 * costs and reading it costs nothing lasting. If the allocation
	 * fails the fixed table still answers, with `dropped` saying how
	 * much it could not.
	 */
	cap = (int)n;
	row = malloc((size_t)cap * sizeof *row);
	if (!row)
		return luaL_error(L, "tracehist: out of memory");

	for (unsigned int i = 0; i < n; i++) {
		struct tracent *e = &t->ent[(start + i) % t->cap];
		int j;

		/* consecutive entries are often the same line -- a loop, or
		 * a line that yields -- so try the last match first, the
		 * same trick the source interning uses one field over.
		 */
		if (last >= 0 && row[last].line == e->line &&
		    row[last].src == e->src) {
			j = last;
		} else {
			for (j = 0; j < nrow; j++)
				if (row[j].line == e->line &&
				    row[j].src == e->src)
					break;
		}
		if (j == nrow) {
			if (nrow >= cap) {
				dropped++;
				continue;
			}
			row[nrow].line = e->line;
			row[nrow].src = e->src;
			row[nrow].count = 0;
			row[nrow].cpu = 0;
			row[nrow].wall = 0;
			nrow++;
		}
		row[j].count++;
		row[j].cpu += e->cpu;
		row[j].wall += e->wall;
		last = j;
	}

	/* selection sort: a few hundred rows, once, in a debugging call.
	 * Anything cleverer would be optimising the reader.
	 */
	for (int i = 0; i < nrow; i++) {
		int best = i;

		for (int j = i + 1; j < nrow; j++)
			if (row[j].cpu > row[best].cpu ||
			    (row[j].cpu == row[best].cpu &&
			     row[j].count > row[best].count))
				best = j;
		if (best != i) {
			struct histrow tmp = row[i];

			row[i] = row[best];
			row[best] = tmp;
		}
	}

	lua_createtable(L, nrow, 1);
	for (int i = 0; i < nrow; i++) {
		lua_createtable(L, 0, 5);
		lua_pushstring(L, row[i].src < t->nname ?
		    t->name[row[i].src] : "?");
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, row[i].line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, (lua_Integer)row[i].count);
		lua_setfield(L, -2, "count");
		lua_pushinteger(L, (lua_Integer)row[i].cpu);
		lua_setfield(L, -2, "cpu");
		lua_pushinteger(L, (lua_Integer)row[i].wall);
		lua_setfield(L, -2, "wall");
		lua_rawseti(L, -2, i + 1);
	}
	/* said rather than silently truncated: a histogram missing rows is
	 * a histogram whose percentages do not mean what they look like.
	 */
	lua_pushinteger(L, (lua_Integer)dropped);
	lua_setfield(L, -2, "dropped");
	free(row);
	return 1;
}

/* There used to be a static fallback table here for when that malloc
 * failed, and a comment saying it was safe because the machine was
 * cooperative and single-threaded. It is not: sys.tracehist is an
 * ordinary syscall, so two procs on two cpus can be inside this at
 * once, both writing one shared array.
 *
 * Raising instead of falling back, rather than locking it, because the
 * lock would have to be held across the table building below -- which
 * allocates in the caller's state and can therefore raise straight
 * through the unlock. A debugger that says "out of memory" is honest;
 * one that quietly shares a buffer is not.
 */
static int
tracehist_read_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, tracehist_read_k);
	case HOLD_SELF:
		lua_pushlightuserdata(L, p);
		lua_replace(L, 1);
		return tracehist_body(L);
	}

	lua_pushcfunction(L, tracehist_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
api_tracehist(lua_State *L)
{
	return tracehist_read_k(L, LUA_OK, 0);
}

/* sys.syscalls(pid): how many of each los.sys call this proc has made.
 *
 * Deliberately not folded into sys.pidstat, which ps calls once per proc
 * and which should not build a thirty-eight entry table each time. Ask
 * for this when the question is "what is it doing", not "what is on the
 * machine".
 *
 * Only calls that have happened are reported, so the table is short and
 * a zero is absence rather than a row of noise.
 */
static int
api_syscalls(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}

	lua_newtable(L);
	for (int i = 0; kapi[i].name && i < NSYSCALL; i++)
		if (p->calls[i]) {
			lua_pushinteger(L, (lua_Integer)p->calls[i]);
			lua_setfield(L, -2, kapi[i].name);
		}
	return 1;
}

/* sys.reap(pid): release a corpse.
 *
 * ambient for the same reason sys.stack is, and the reasoning survives
 * the fact that this one destroys something: what it destroys is
 * already dead. a corpse holds no rights and will never run again, so
 * the only thing lost is a debugging record that MAXBROKE was going to
 * discard on the next crash anyway. the threat model here is buggy lua,
 * not a proc that wants to hide its own death -- and a proc that wanted
 * to could simply not break.
 *
 * this is also why it cannot be PRIV_BOOT: /proc is a dev backend, so
 * writing /proc/<pid>/ctl runs procfs code inside whichever proc has it
 * mounted, which for any shell is not proc 0. gating on boot would
 * leave the file there and always failing.
 */
static int
api_reap(lua_State *L)
{
	struct kproc *p = find_proc((int)luaL_checkinteger(L, 1));

	if (!p)
		return luaL_error(L, "no such proc");
	if (p->status != BROKE)
		return luaL_error(L, "proc %d is not broke", p->id);
	proc_reap(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.kill(pid): stop a proc that will not stop on its own.
 *
 * The cooperative path is the hangup cascade -- a proc watching its own
 * port exits when its clients leave, and a shutdown drops rights and lets
 * that flow down the mounts (test/boot/microvm_gefsshutdown.lua). This is
 * the backstop for a proc that ignores it, a loop that never parks, so a
 * shutdown can reclaim it after a deadline instead of waiting forever.
 *
 * It becomes a corpse exactly as a crash does: proc_break detaches it --
 * wait_clear and rq_del unlink it from whatever port or run queue it sits
 * on, its rights drop (which is what makes killing a client hang up the
 * server below it), and its monitors are told -- then it is held BROKE
 * for inspection and reaping. The target is never the running proc, so
 * its state is freed later by reap, not here; killing self is refused
 * because freeing the caller mid-syscall is not a thing to smuggle in.
 *
 * Ambient, like sys.reap and sys.monitor beside it: proc management here
 * is deliberately not gated, and a kill capability can narrow it later
 * without changing this shape. The threat model is a wedged proc, not a
 * hostile one -- a hostile proc could as easily spin and never die.
 */
static int
api_kill(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc(pid);

	if (target == p)
		return luaL_error(L, "cannot kill self");
	if (!target || target->status == BROKE || target->status == DEAD) {
		lua_pushboolean(L, 0);	/* nothing to kill: already gone */
		return 1;
	}
	proc_break(target, "killed");
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.set_priority(pid, weight): a scheduling POLICY knob, not the
 * scheduler itself -- this just writes a clamped integer into the
 * target proc's kproc struct. kernel_run's dispatch loop (the
 * mechanism) reads it mechanically every lap; no lua code ever runs
 * synchronously inside a scheduling decision, so a crashing "sched"
 * proc that computes weights however it likes can never wedge or
 * corrupt the dispatch loop itself -- same reason sched_ext's eBPF
 * programs are verified/bounded rather than being the dispatcher.
 * weight=1 is the default (plain round-robin); higher weight is a
 * proportionally bigger share, via getting resumed up to `weight`
 * times per lap instead of once (see kernel_run).
 *
 * gated on the scheduling capability (a right to schedport, handle
 * "sched" in sys.granted()), exactly like disk writes are gated on a
 * to diskport. without it any ordinary sys.spawn child could hand
 * itself weight=MAXWEIGHT and starve every other proc, which is a
 * denial of service the capability model is supposed to prevent.
 */
static int
api_set_priority(lua_State *L)
{
	int pid = (int)luaL_checkinteger(L, 1);
	int weight = (int)luaL_checkinteger(L, 2);
	struct kproc *p = find_proc(pid);

	if (!proc_has_port(self(L), schedport))
		return luaL_error(L, "no scheduling capability");
	if (!p)
		return luaL_error(L, "no such proc");
	if (weight < 1)
		weight = 1;
	if (weight > MAXWEIGHT)
		weight = MAXWEIGHT;
	p->weight = weight;
	return 0;
}

/* reading a weight is not gated: it's the same class of information
 * sys.procs()/sys.meminfo() already hand out for free.
 */
/* sys.priority(pid) -> weight, pri, cpu
 *
 * weight is the static capability-gated knob, pri what the feedback
 * computes from it, cpu per-mille of wall time decayed. nothing
 * dispatches on pri yet -- it is exposed first so the numbers can be
 * watched before anything bets on them.
 */
static int
api_priority(lua_State *L)
{
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *p = find_proc(pid);

	if (!p)
		return luaL_error(L, "no such proc");
	lua_pushinteger(L, p->weight);
	lua_pushinteger(L, reprioritize(p, count_runnable()));
	lua_pushinteger(L, (lua_Integer)p->cpu);
	return 3;
}

/* sys.pidstat(pid): everything ps wants about one proc, in one table
 * and one call.
 *
 * The alternative was another single-value accessor beside name,
 * meminfo, priority and wchan, and four is already the point at which
 * rendering one row costs four kernel entries and adding a column means
 * adding an entry point. A table has room to grow without either.
 *
 * The older accessors stay: they are what tests and /proc read, and
 * they now share push_wchan with this rather than describing a proc
 * twice.
 */
static int
api_pidstat(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}

	lua_createtable(L, 0, 10);
	lua_pushinteger(L, p->id);
	lua_setfield(L, -2, "pid");
	lua_pushstring(L, p->name);
	lua_setfield(L, -2, "name");
	/* which cpu dispatches it. Distinct from "cpu" below, which is a
	 * share of one; reported so placement can be seen from a test
	 * rather than inferred from timing.
	 */
	lua_pushinteger(L, (lua_Integer)p->home);
	lua_setfield(L, -2, "home");
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_setfield(L, -2, "used");
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_setfield(L, -2, "peak");
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	lua_setfield(L, -2, "limit");
	lua_pushinteger(L, p->weight);
	lua_setfield(L, -2, "weight");
	/* raw tsc cycles this proc has actually spent running, which the
	 * scheduler has accumulated since the beginning for its own decay
	 * and which nothing could read until now.
	 *
	 * It answers a question no other tool here can. A line trace fires
	 * only inside lua, so the kernel's own work -- dispatch, port push
	 * and pop, serialising a message -- appears in no proc's trace at
	 * all; and instrumenting a task measures the instrumentation. Two
	 * reads of this around a piece of work attribute it across procs
	 * exactly, with nothing added to any hot path, and whatever the
	 * wall clock has that the sum does not is the kernel's.
	 */
	lua_pushinteger(L, (lua_Integer)p->cputime);
	lua_setfield(L, -2, "cputime");
	lua_pushinteger(L, reprioritize(p, count_runnable()));
	lua_setfield(L, -2, "pri");
	lua_pushinteger(L, (lua_Integer)p->cpu);
	lua_setfield(L, -2, "cpu");
	lua_pushinteger(L, (lua_Integer)p->nresume);
	lua_setfield(L, -2, "resumes");
	push_wchan(L, p);
	lua_setfield(L, -2, "wchan");
	return 1;
}

/* sys.granted(): {name = handle} for every capability the kernel
 * handed this proc at spawn. empty for an ordinary sys.spawn child,
 * which is granted nothing; populated for the boot payload. absent key
 * means "this machine doesn't have that" -- see struct grant.
 */
static int
api_granted(lua_State *L)
{
	struct kproc *p = self(L);
	struct grant *g;

	lua_newtable(L);
	SLIST_FOREACH(g, &p->grants, e) {
		lua_pushinteger(L, g->handle);
		lua_setfield(L, -2, g->name);
	}
	return 1;
}

static int
api_ticks(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)platform_ticks());
	return 1;
}

/* sys.timer(ms): a receive right to a fresh port that gets exactly one
 * message (true) after roughly ms milliseconds. returns nil if the timer
 * table or the caller's rights table is full -- callers must handle that,
 * same as sys.newport().
 *
 * cancel by closing the right: the port dies, and expire_timers() reaps
 * the slot on its next pass without ever delivering.
 */
static int
api_timer(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer ms = luaL_checkinteger(L, 1);

	if (ms < 0)
		ms = 0;

	int slot = -1;

	/* everything from here down is shared -- the timer table, the
	 * port table, this proc's rights -- and nothing in it raises:
	 * the failure paths all return 0 to lua rather than erroring.
	 * So one region covers the whole of it.
	 */
	ipclock_enter();
	for (int tries = 0; tries < 2 && slot < 0; tries++) {
		for (int i = 0; i < MAXTIMERS; i++)
			if (!timers[i].port) {
				slot = i;
				break;
			}
		/* full: a cancelled timer's slot is held until something
		 * notices its port died, and the caller cannot be asked to
		 * yield first -- thread.sleep() would need a timer of its
		 * own to do that, which is exactly what it cannot get.
		 * reclaim them here instead.
		 */
		if (slot < 0 && tries == 0)
			reap_dead_timers();
	}
	if (slot < 0) {
		ipclock_leave();
		return 0;
	}

	struct kport *port = port_new();

	if (!port) {
		ipclock_leave();
		return 0;
	}

	int h = right_new(p, port, 1);

	if (h < 0) {
		port->used = 0;
		ipclock_leave();
		return 0;
	}
	port->nrights++;	/* the timer table's own ref */
	timers[slot].port = port;
	timers[slot].due_ms = uptime_ms() + (unsigned long long)ms;
	ipclock_leave();
	lua_pushinteger(L, h);
	return 1;
}

/* sys.hungup(h): is this proc the ONLY holder of the port behind h?
 *
 * that is our eof, and the formulation matters. plan 9's devpipe counts
 * opens of each end (qref) and calls qhangup on the peer's queue when a
 * count hits zero -- it can, because a Chan is explicitly a read or a
 * write end. our rights make no such distinction: api_send never checks
 * r->recv, so ANY right can send, and recv only feeds port-death
 * bookkeeping. "no senders left" is therefore not a question our model
 * can answer.
 *
 * "am I the only holder" is, and for a pipe it means the same thing: if
 * nobody else has a right, nobody can ever write again, so whatever is
 * queued is all there will be. in-flight rights inside undelivered
 * messages still count toward nrights, so a right on its way to a new
 * writer correctly keeps the pipe open.
 *
 * the pipe's creator must drop its own right after handing the ends out,
 * or it stays a holder forever and eof never arrives.
 */
static int
api_hungup(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r)
		return luaL_error(L, "bad right");
	lua_pushboolean(L, r->port->nrights <= 1);
	return 1;
}

/* sys.setexit(status): record this proc's exit status, reported to
 * whoever monitors it. does NOT terminate anything -- the proc goes on
 * to end however it was going to.
 *
 * split that way on purpose. a real exit() has to unwind from arbitrary
 * depth, which from C means raising, and a raise can be swallowed by any
 * pcall between here and the top. keeping the status separate from the
 * unwinding means lib/prog.lua implements os.exit() as "record, then
 * raise a sentinel it catches itself", and the kernel needs no special
 * case in its error path at all.
 *
 * status may be a NUMBER or a STRING, and both are meant:
 *
 *   nil / 0     success, plan 9's exits(nil)
 *   n           posix status n, what a ported utility's os.exit(1) does
 *   "why"       plan 9's exits("why") -- also reported as status 1, so
 *               a numeric consumer still sees failure
 *
 * plan 9 makes exit status a string for the same reason 9P makes Rerror
 * one: a number is useless without a table to look it up in. we already
 * took that argument for errors (see lib/dev.lua's 9front strings), so
 * taking it here too is consistency rather than novelty. the number
 * survives because the utilities being ported call os.exit(1) and the
 * whole point is that they need no diff.
 */
static int
api_setexit(lua_State *L)
{
	struct kproc *p = self(L);

	p->exitmsg[0] = 0;
	if (lua_isnoneornil(L, 1)) {
		p->exitcode = 0;
	} else if (lua_type(L, 1) == LUA_TSTRING) {
		snprintf(p->exitmsg, sizeof p->exitmsg, "%s",
		    lua_tostring(L, 1));
		p->exitcode = 1;
	} else {
		p->exitcode = (int)luaL_checkinteger(L, 1);
	}
	return 0;
}

/* sys.uptime_ms(): milliseconds since boot, from the calibrated tsc.
 * prefer this to sys.ticks() for anything time-shaped -- ticks() is a
 * raw cycle counter whose rate differs per machine.
 */
static int
api_uptime_ms(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)uptime_ms());
	return 1;
}

/* registry key for a proc's atexit list -- its address is the key, so it
 * cannot collide with a lua string key. Shared across a state's threads,
 * since the registry is per global state.
 */
static const char atexit_key = 0;

/* sys.atexit(fn): run fn when this proc's main function returns normally,
 * in the order registered's reverse (LIFO, like C atexit). The handler
 * runs after main has returned, in the main state and OUTSIDE the
 * scheduler's resume of the proc -- so it must not yield or block. That
 * is enough for the things an exit handler wants: send a last message,
 * close a right, log. It does not run on an error exit (a broke proc is
 * held for inspection, not cleaned up) nor on sys.kill.
 */
static int
api_atexit(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TFUNCTION);

	if (lua_rawgetp(L, LUA_REGISTRYINDEX, &atexit_key) != LUA_TTABLE) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_rawsetp(L, LUA_REGISTRYINDEX, &atexit_key);
	}
	lua_pushvalue(L, 1);
	lua_rawseti(L, -2, luaL_len(L, -2) + 1);
	lua_pop(L, 1);
	return 0;
}

static const luaL_Reg kapi[] = {
	{ "send", api_send },
	{ "call", api_call },
	{ "tryrecv", api_tryrecv },
	{ "block", api_block },
	{ "sendblock", api_sendblock },
	{ "altblock", api_altblock },
	{ "altpoll", api_altpoll },
	{ "anyready", api_anyready },
	{ "hangups", api_hangups },
	{ "altrecv", api_altrecv },
	{ "altrecvnb", api_altrecvnb },
	{ "yield", api_yield },
	{ "newport", api_newport },
	{ "sendright", api_sendright },
	{ "spawn", api_spawn },
	{ "monitor", api_monitor },
	{ "close", api_close },
	{ "stats", api_stats },
	{ "meminfo", api_meminfo },
	{ "self", api_self },
	{ "procs", api_procs },
	{ "ports", api_ports },
	{ "granted", api_granted },
	{ "name", api_procname },
	{ "wchan", api_wchan },
	{ "stack", api_stack },
	{ "reap", api_reap },
	{ "atexit", api_atexit },
	{ "kill", api_kill },
	{ "set_trace", api_set_trace },
	{ "set_torture", api_set_torture },
	{ "trace", api_trace },
	{ "tracehist", api_tracehist },
	{ "syscalls", api_syscalls },
	{ "set_priority", api_set_priority },
	{ "priority", api_priority },
	{ "pidstat", api_pidstat },
	{ "ticks", api_ticks },
	{ "uptime_ms", api_uptime_ms },
	{ "timer", api_timer },
	{ "setexit", api_setexit },
	{ "hungup", api_hungup },
	{ NULL, NULL }
};

/* the counters are indexed by position in the table above, so a table
 * that outgrew them would run off the end of calls[] into whatever
 * follows it in struct kproc. los_sys_open checks this too, but only
 * when a proc opens los.sys, and reports it by killing that proc. The
 * size is known right here, so say it right here: adding the 65th
 * syscall should fail the build rather than the machine.
 */
_Static_assert(sizeof kapi / sizeof kapi[0] - 1 <= NSYSCALL,
    "NSYSCALL too small for kapi");

extern int luaopen_los_efi(lua_State *L);		/* los.c: firmware info */
extern int luaopen_los_fs(lua_State *L);		/* dirs.c: readdir/stat */
extern int luaopen_los_inet(lua_State *L);		/* inet.c: checksum */
extern int luaopen_los_crc(lua_State *L);		/* crc.c: crc16/crc32 */
extern int luaopen_los_font(lua_State *L);		/* font.c: glyphs */
extern int luaopen_los_rom(lua_State *L);		/* vfs.c: the embed set */
extern int luaopen_ssh_crypto_native(lua_State *L);	/* native.c */
extern int luaopen_gefs_native(lua_State *L);	/* gefs_native.c */
extern int luaopen_los_platform_cons(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_wire(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_power(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_p9(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_eth(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_blk(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_flash(lua_State *L);	/* drivers.c: esp32 only, no-op elsewhere */
extern int luaopen_los_platform_wifi(lua_State *L);	/* drivers.c: esp32 only, no-op elsewhere */
extern int luaopen_los_platform_fb(lua_State *L);	/* gop.c: efi only, no-op elsewhere */

/* the los.sys module: the microkernel abi (ports, rights, procs) plus
 * kernel-owned primitives that outlive efi (ticks). registered in
 * package.preload by proc_new; a chunk pulls it in with an explicit
 * require("los.sys"). the proc pointer comes from the state's extra
 * space, so the api needs no upvalues.
 */
/* One los.sys call, counted.
 *
 * A wrapper at registration rather than an increment inside each of the
 * thirty-eight api_ functions, because registration is the single door:
 * a syscall added to kapi later is counted without anyone remembering
 * to, and the one that someone forgets is invisible in exactly the way
 * that matters. The arguments are already on the stack, so forwarding is
 * a call and nothing else.
 *
 * Counts only, no cycles. Two tsc reads per syscall would be real
 * overhead on the cheapest ones, and the line profile already prices the
 * line a syscall sits on -- what it cannot say is how many calls that
 * line made and which. This closes exactly that gap: the case it was
 * built for was task/tcp4.lua closing and recreating a timer on every
 * message, which sys.tracehist could point at only as "the scan around
 * it", because a syscall is not a Lua line.
 */
static int
counted(lua_State *L)
{
	struct kproc *p = self(L);
	lua_CFunction f = (lua_CFunction)lua_touserdata(L,
	    lua_upvalueindex(1));

	if (p)
		p->calls[lua_tointeger(L, lua_upvalueindex(2))]++;
	return f(L);
}

static int
los_sys_open(lua_State *L)
{
	int n = 0;

	while (kapi[n].name)
		n++;
	/* a table that outgrew its counters would silently stop counting
	 * the tail of itself, so say so at the door instead.
	 */
	if (n > NSYSCALL)
		return luaL_error(L, "NSYSCALL too small for kapi (%d)", n);

	lua_createtable(L, 0, n);
	for (int i = 0; i < n; i++) {
		lua_pushlightuserdata(L, (void *)(intptr_t)kapi[i].func);
		lua_pushinteger(L, i);
		lua_pushcclosure(L, counted, 2);
		lua_setfield(L, -2, kapi[i].name);
	}

	/* SELF is the only well-known handle, and the only one that can
	 * be: it is how a proc receives at all, so there is nothing to
	 * bootstrap it from. everything else -- cons, wire, power, disk,
	 * tcp, udp, sched -- is granted at whatever slot right_new picked
	 * and looked up BY NAME through sys.granted(). the numbers are
	 * not an abi and nothing may hardcode them.
	 *
	 * they used to be fixed constants, which broke exactly the way
	 * fixed numbers do: an ungranted one (no NIC, so no tcp task)
	 * left an empty slot, right_new's first-free search handed that
	 * slot to the next sys.spawn child, and sys.TCP silently became
	 * a right to that child. a name that isn't in the mapping cannot
	 * alias anything.
	 */
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "SELF");

	/* the serializer's ceiling on one message, so a client that has to
	 * split a large payload can ask instead of hardcoding it. reported
	 * rather than merely enforced because the alternative is every
	 * caller carrying its own copy of the number and one of them being
	 * wrong after it changes -- lib/caps.lua's fb.load splits raw pixel
	 * rectangles on exactly this bound.
	 *
	 * the whole message is bounded by this, not just the payload
	 * string, so a caller splitting to exactly MAXMSG still fails on
	 * the table around it. leave room.
	 */
	lua_pushinteger(L, MAXMSG);
	lua_setfield(L, -2, "MAXMSG");
	return 1;
}

/* los.thread, compiled on first require rather than at every spawn.
 *
 * It used to be luaL_loadfile at proc_new, which read and compiled
 * ~17K of lua source into every state whether the proc ever asked for
 * it or not -- only the *call* was deferred, and a compiled chunk is
 * resident either way.
 *
 * Safe to do from inside require even though loadlib.c calls a preload
 * function with a plain lua_call and so cannot yield: this reads
 * through the C fs interface, not through the proc's namespace, so
 * there is no IPC and nothing to block on. The path is fixed, so a proc
 * gains no reach it did not have -- it is the same read proc_new was
 * doing on its behalf.
 */
static int
los_thread_open(lua_State *L)
{
	if (luaL_loadfile(L, "/lib/thread.lua") != LUA_OK)
		return lua_error(L);
	lua_call(L, 0, 1);
	return 1;
}

/* ---- proc lifecycle ---- */

/* chunks for the lua heap.
 *
 * Through malloc, and so through the firmware's pool, which does cost
 * something: the machine loses about 1.26 bytes of conventional memory
 * per byte the heap believes it mapped, and malloc_stats cannot see the
 * difference because AllocatePool's metadata is not ours.
 *
 * Taking whole pages instead -- AllocatePages, no pool, no malloc header,
 * the chunk header already living inside the chunk -- looks like the
 * obvious fix and measured three times worse: 1.77 bytes per mapped byte
 * against 1.26, and 73216 bytes per proc against 52224. The excess was
 * also flat across 8K and 64K chunks, so it is not per-call overhead
 * being amortised badly; the pool is simply better at reusing pages it
 * already holds than we are at asking for new ones. Do not retry this
 * without re-measuring both.
 */
static void *
kalloc_chunk(void *ud, size_t n)
{
	(void)ud;
	return platform_chunk_alloc(n);
}

static void
kalloc_free_chunk(void *ud, void *p, size_t n)
{
	(void)ud;
	platform_chunk_free(p, n);
}

static const struct luaheap_ops kalloc_ops = {
	.chunk_alloc = kalloc_chunk,
	.chunk_free = kalloc_free_chunk,
};


/* print(), for a proc that has not redirected it. See src/coreg.h: this
 * is what lua_writestring becomes, so an unredirected diagnostic
 * reaches the console rather than a stdio that may discard it.
 */
void
kernel_stdout(const char *s, size_t n)
{
	console_write(s, n);
}

/* lua allocator with per-proc accounting. note lua's convention: when
 * ptr is NULL, osize carries the object type, not a size. luaheap is
 * given a real size instead, and depends on it being one -- that is
 * what lets a block carry no header.
 */
static void *
kalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	struct kproc *p = ud;
	size_t real_osize = ptr ? osize : 0;

	if (nsize == 0) {
		luaheap_realloc(p->heap, ptr, real_osize, 0);
		p->mem_used -= real_osize;
		return 0;
	}
	/* enforce the limit only on growth so gc/shrink always succeeds.
	 * The limit is on what lua asked for, not on what the heap mapped
	 * to serve it, so a proc's budget means the same thing it did
	 * before this allocator existed.
	 */
	if (p->mem_limit && nsize > real_osize &&
	    p->mem_used - real_osize + nsize > p->mem_limit)
		return 0;

	void *q = luaheap_realloc(p->heap, ptr, real_osize, nsize);

	if (!q)
		return 0;
	p->mem_used += nsize - real_osize;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	return q;
}

/* tear down a proc's state.
 *
 * lua_close cannot be skipped even though the heap is about to be
 * destroyed whole: __gc finalizers are how handles get clunked, so
 * dropping the memory without running them would leak what the memory
 * was only pointing at. Destroying the heap afterwards is what returns
 * the chunks, which a shared heap could not do.
 */
static void
proc_freestate(struct kproc *p)
{
	if (p->L)
		lua_close(p->L);
	p->L = 0;
	p->co = 0;
	/* after lua_close, never before: the finalizers it runs are
	 * still allocating and freeing in this heap.
	 */
	if (p->heap && p->heap != shared_heap) {
		luaheap_destroy(p->heap);
	}
	p->heap = 0;
	/* lua_close frees every coroutine through kernel_cofree, so the
	 * list is already empty; re-init rather than trust that, since a
	 * reused slot would inherit whatever is left
	 */
	TAILQ_INIT(&p->coros);
	p->hookforced = 0;
	/* the trace outlives the death and not the state: it is freed
	 * here, with the heap it describes, so a corpse still answers
	 * "how did it get there" for as long as it answers "where"
	 */
	if (p->trace) {
		free(p->trace->ent);
		free(p->trace);
		p->trace = 0;
	}
}

/* lua's per-state creation and teardown hooks (src/coreg.h).
 *
 * costart runs after lua has copied the new state's extra space from
 * the main thread, so the kproc pointer is already right and only the
 * links need setting. cofree runs before the state's memory goes back,
 * which is the last moment the link is still valid -- and it is reached
 * for every coroutine, including on lua_close, since that frees them
 * through the same path.
 *
 * a state created before the proc's own pointer is in place (the main
 * state itself) has no proc to be listed under and is simply not
 * listed; the kernel never needs to arm it, because the chunk runs in
 * p->co and every coroutine descends from there.
 */
void
kernel_costart(lua_State *from, lua_State *nw)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(nw);
	struct kproc *p = ((struct kextra *)lua_getextraspace(from))->p;

	kx->p = p;
	kx->preempted = 0;
	memset(&kx->link, 0, sizeof kx->link);
	if (p && p->coros.tqh_last)
		TAILQ_INSERT_TAIL(&p->coros, kx, link);
}

void
kernel_cofree(lua_State *from, lua_State *dead)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(dead);

	(void)from;
	if (kx->p && kx->link.tqe_prev)
		TAILQ_REMOVE(&kx->p->coros, kx, link);
	memset(&kx->link, 0, sizeof kx->link);
}

/* the closest thing we have to plan 9's hzsched.
 *
 * plan 9 preempts from the clock interrupt, so it can decide "you have
 * had your 100ms" regardless of what the running proc is doing. we have
 * no interrupt: this hook is our only preemption, and it fires every N
 * lua VM instructions.
 *
 * a slice was therefore N INSTRUCTIONS, which is a poor unit -- how much
 * wall time it buys depends entirely on how expensive those opcodes are,
 * so two procs doing equal instruction counts got wildly unequal machine
 * time. the hook now yields only once a wall-clock QUANTUM has elapsed,
 * using the instruction count purely as the sampling rate. slices are
 * therefore ~QUANTUM_MS of real time, checked every N instructions.
 *
 * be clear about the trade: this makes each slice LONGER, not shorter.
 * 25000 instructions is roughly 200us, so a compute-bound proc now holds
 * the cpu for 2ms instead of yielding ten times. that is fewer context
 * switches (measured: +4% on a spin loop) at the cost of up to 2ms of
 * added latency for anyone waiting -- which is only paid when something
 * is actually compute-bound, since a proc that blocks yields at once.
 *
 * it does NOT fix the real hole, and nothing here can: the hook cannot
 * fire inside a single C call, so string.rep("x", 1e8) holds the machine
 * for as long as it takes. that needs an interrupt, which means leaving
 * boot services.
 */
/* record one line. only ever called from a line event, where lua has
 * already filled ar->currentline -- asking lua_getinfo for it would be
 * paying twice for something the hook was handed.
 */
/* the only place a hook mask is decided.
 *
 * LUA_MASKCOUNT is not conditional and must never become so: it is the
 * preemption budget, and a proc whose count hook went missing holds the
 * machine until it blocks. tracing can only ever ADD LUA_MASKLINE to
 * it, and every lua_sethook in this kernel goes through here with
 * p->reductions rather than naming a mask of its own, so turning
 * tracing off cannot be a route to turning preemption off with it.
 */
static int
proc_hookmask(struct kproc *p)
{
	return LUA_MASKCOUNT | (p->trace ? LUA_MASKLINE : 0);
}

/* arm every coroutine of a proc at `count`.
 *
 * every one, not just p->co: lua_newthread copies the hook when it is
 * created and never looks again, so a mask or count set on one
 * coroutine reaches no other. the list is exact (src/coreg.h) rather
 * than inferred from reachability, which matters both for a coroutine
 * held only from a C closure's upvalue and for being able to do this
 * from inside the hook without allocating.
 */
static void
proc_armall(struct kproc *p, int count)
{
	struct kextra *kx;

	if (!p->L || !p->co)
		return;
	TAILQ_FOREACH(kx, &p->coros, link)
		lua_sethook(kx_state(kx), preempt_hook, proc_hookmask(p),
		    count);
}

static void
proc_rearm(struct kproc *p)
{
	proc_armall(p, p->reductions);
}

/* record one line. only ever called from a line event, where lua has
 * already filled ar->currentline -- asking lua_getinfo for it would be
 * paying twice for something the hook was handed.
 */
static void
trace_line(struct kproc *p, lua_State *L, lua_Debug *ar)
{
	struct ktrace *t = p->trace;
	int src = 0, co = 0;

	if (!t || !t->cap)
		return;

	/* "S" is push-free and call-free, the same reason src/debug.c
	 * asks for "Sln" and not "f" or "L": a hook that could run target
	 * code or allocate in the target would be changing the thing it
	 * is recording.
	 */
	if (lua_getinfo(L, "S", ar) && ar->source) {
		if (ar->source == t->lastsrc) {
			src = t->lastid;
		} else {
			for (src = 0; src < t->nname; src++)
				if (!strcmp(t->name[src], ar->short_src))
					break;
			if (src == t->nname) {
				if (t->nname >= TRACESRC)
					src = 0;	/* out of slots */
				else
					snprintf(t->name[t->nname++],
					    LUA_IDSIZE, "%s", ar->short_src);
			}
			t->lastsrc = ar->source;
			t->lastid = src;
		}
	}

	/* which coroutine, by identity only: the pointer names a thread
	 * for as long as this trace is worth reading and is never
	 * dereferenced. lib/thread procs interleave threads line by
	 * line, and a trace that could not tell them apart would read as
	 * one impossible execution.
	 */
	for (co = 0; co < t->nco; co++)
		if (t->co[co] == (const void *)L)
			break;
	if (co == t->nco) {
		if (t->nco >= TRACECO)
			co = 0;
		else
			t->co[t->nco++] = (const void *)L;
	}

	trace_put(p, t, ar->currentline, src, co);
}

/* One entry, with both clocks.
 *
 * A single platform_ticks() yields both: the wall reading directly, and
 * this proc's running cycles as cputime plus however long it has been
 * on the cpu since it was resumed. p->resumed exists for exactly this
 * -- its own comment says "for the hook" -- so nothing new has to be
 * tracked to get the second number.
 */
static void
trace_put(struct kproc *p, struct ktrace *t, int line, int src, int co)
{
	unsigned long long now = platform_ticks();
	unsigned long long cpu = p->cputime +
	    (p->resumed && now > p->resumed ? now - p->resumed : 0);
	struct tracent *e;

	/* The elapsed time belongs to the PREVIOUS entry, not this one.
	 *
	 * A line hook fires before its line runs, so the interval between
	 * two hooks is the cost of the earlier line. Recording it against
	 * the arriving entry shifts the whole profile down by one, and the
	 * shift is not harmless: it blamed `snd_una = seg.ack` for 7.5% of
	 * a tcp task, when the cost was the reslice of the send buffer on
	 * the line above it. A profile that names the wrong line is worse
	 * than none, because the wrong line is usually innocent and cheap
	 * and the reader concludes something strange is happening.
	 *
	 * The newest entry therefore carries zero until the next line
	 * arrives, which is honest: nothing has happened after it yet.
	 */
	if (t->n > 0) {
		struct tracent *prev = &t->ent[(t->n - 1) % t->cap];
		unsigned long long dw = now - t->lastwall;
		unsigned long long dc = cpu > t->lastcpu ? cpu - t->lastcpu : 0;

		/* saturate rather than wrap: a proc that was away for a
		 * second is worth seeing as "a very long time" and not as a
		 * small number.
		 */
		prev->wall = dw > 0xffffffffull ? 0xffffffffu :
		    (unsigned int)dw;
		prev->cpu = dc > 0xffffffffull ? 0xffffffffu :
		    (unsigned int)dc;
	}

	e = &t->ent[t->n % t->cap];
	e->line = line;
	e->src = (unsigned short)src;
	e->co = (unsigned short)co;
	e->wall = 0;
	e->cpu = 0;

	t->lastwall = now;
	t->lastcpu = cpu;
	t->n++;
}

/* A marker entry, for something that is not a line of Lua.
 *
 * A context switch is the one that matters. Without it the gap shows up
 * as an enormous wall delta on whichever line happened to run last, and
 * the reader has to guess whether that line was slow or the proc was
 * simply not running. With it the discontinuity is a thing in the trace
 * rather than an adjustment to be trusted -- and the histogram has
 * somewhere honest to put those intervals instead of blaming a line.
 *
 * The name is interned in the same table as a source file, so it costs
 * one of TRACESRC's slots and reads as a filename with line 0.
 */
static void
trace_mark(struct kproc *p, const char *what)
{
	struct ktrace *t = p ? p->trace : 0;
	int src;

	if (!t || !t->cap)
		return;

	for (src = 0; src < t->nname; src++)
		if (!strcmp(t->name[src], what))
			break;
	if (src == t->nname) {
		if (t->nname >= TRACESRC)
			return;		/* out of slots; a marker is not worth evicting a file */
		snprintf(t->name[t->nname++], LUA_IDSIZE, "%s", what);
	}

	/* the source cache names a lua string pointer, and this is not
	 * one -- clear it so the next real line re-interns rather than
	 * matching a marker's slot.
	 */
	t->lastsrc = 0;
	trace_put(p, t, 0, src, 0);
}

static void
preempt_hook(lua_State *L, lua_Debug *ar)
{
	struct kproc *p = *(struct kproc **)lua_getextraspace(L);

	/* a line event is a trace event and nothing else. preemption
	 * stays entirely on the count event, so turning tracing on does
	 * not change when a proc yields -- the scheduling this hook
	 * exists for is the same whether or not anyone is watching.
	 */
	if (ar->event == LUA_HOOKLINE) {
		if (p)
			trace_line(p, L, ar);
		return;
	}
	/* the forced trip below leaves states sampling every instruction.
	 * put them back the moment it has done its job, which is the
	 * first time the hook fires on p->co afterwards.
	 */
	if (p && L == p->co && p->hookforced) {
		if (p->hookforced == 2)
			proc_armall(p, p->reductions);
		else
			lua_sethook(p->co, preempt_hook, proc_hookmask(p),
			    p->reductions);
		p->hookforced = 0;
	}
	if (!lua_isyieldable(L))
		return;

	/* torture: cut this thread between EVERY pair of instructions,
	 * rather than wherever the quantum happens to land.
	 *
	 * A race between a thread and thread.run is a window of one or
	 * two instructions, and whether a run lands in one is a question
	 * of how many preemptions the work gets cut into -- which is why
	 * this class of bug is found on slow hardware and not on fast.
	 * This stops leaving it to chance: every window is landed on,
	 * every run.
	 *
	 * Threads only (L != p->co). The point is to interleave a proc's
	 * THREADS, and that needs no more than a yield to thread.run --
	 * which is why the forced walk-out to p->co below is deliberately
	 * skipped here: it would put a kernel round trip between every
	 * pair of instructions and turn a ten second test into an
	 * afternoon.
	 *
	 * The cost of skipping it is that a tortured proc does not honour
	 * its quantum while a thread is running, so it can hold the cpu
	 * for as long as that thread cares to. That is exactly the
	 * property a027800 exists to protect, which is why this is
	 * PRIV_BOOT only and why nothing but a test payload should ever
	 * ask for it. The proc's own main coroutine is left alone and
	 * still trips the quantum below, so a tortured proc that returns
	 * to thread.run is descheduled normally.
	 */
	if (p && p->torture && L != p->co) {
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
		lua_yield(L, 0);
		return;		/* not reached */
	}

	if (p && p->resumed && quantum_cycles &&
	    platform_ticks() - p->resumed < quantum_cycles)
		return;		/* under quantum: let it keep the cpu */

	/* yielding only ever reaches the resumer of the state the hook
	 * fired in. for a thread that is the proc's own scheduler, one
	 * level down from the kernel, so yielding here suspends the
	 * thread and hands the cpu straight back to thread.run -- the
	 * proc keeps the machine and the quantum means nothing. measured
	 * with a spinner inside a thread, everything else on the machine
	 * got 0.02 of its fair share.
	 *
	 * lua has no yield-across-levels to ask for, so the trip is
	 * forced instead: arm the proc's outermost state to fire on its
	 * very next instruction. the thread yields to thread.run,
	 * thread.run runs one instruction, and the hook fires again with
	 * L == p->co, where a yield does reach the kernel.
	 *
	 * that also lands the proc in the right place. resuming into the
	 * interrupted coroutine would let one thread hold the cpu across
	 * proc slices; resuming into thread.run leaves the choice of what
	 * runs next where it belongs, with the scheduler that owns
	 * threads. the kernel picks procs, thread.run picks threads, and
	 * neither has to know how the other decides.
	 */
	if (p && L != p->co) {
		if (p->hookforced) {
			/* p->co was already armed and still has not been
			 * reached, so the chain is deeper than one level:
			 * a thread running a scheduler of its own never
			 * returns to p->co on its own. arm every
			 * coroutine instead, and the yield walks out one
			 * instruction per level.
			 */
			proc_armall(p, 1);
			p->hookforced = 2;
		} else {
			lua_sethook(p->co, preempt_hook, proc_hookmask(p),
			    1);
			p->hookforced = 1;
		}
	}
	/* the resumer of a state that is not p->co is lua code that never
	 * asked for this. kernel_cowrap reads the mark and resumes again
	 * rather than reporting a coroutine that is not finished as
	 * finished; a scheduler using coroutine.resume sees the yield
	 * itself and handles it, which is what lib/thread.lua does.
	 */
	if (p && L != p->co)
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
	lua_yield(L, 0);
}

static int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file,
    int reductions, size_t mem_limit, int priv)
{
	struct kproc *p = 0;

	for (int i = 0; i < MAXPROCS; i++)
		if (!procv[i] || procv[i]->status == DEAD) {
			if (!procv[i]) {
				procv[i] = malloc(sizeof *procv[i]);
				if (!procv[i])
					return -1;
				memset(procv[i], 0, sizeof *procv[i]);
			}
			p = procv[i];
			/* a reused slot still holds the last occupant's
			 * fields; only the id must survive nothing, so wipe
			 * it rather than trusting every assignment below to
			 * cover every field
			 */
			memset(p, 0, sizeof *p);
			if (i >= prochigh)
				prochigh = i + 1;
			break;
		}
	if (!p)
		return -1;

	memset(p->rights, 0, sizeof p->rights);
	p->nwatch = 0;
	p->reductions = reductions > 0 ? reductions : default_reductions;
	p->mem_used = 0;
	p->mem_peak = 0;
	/* the limit goes live only after setup: base state + libraries
	 * are counted but never refused, so a tiny limit can't panic
	 * openlibs. the chunk's first over-limit allocation then fails
	 * inside the protected resume (clean LUA_ERRMEM death).
	 */
	p->mem_limit = 0;
	/* before any lua_State exists: kernel_costart consults this to
	 * decide whether the proc is ready to own coroutines
	 */
	TAILQ_INIT(&p->coros);
	p->hookforced = 0;
	/* No placement. There is one run queue for the machine, so
	 * whichever cpu looks next runs this proc, and it is not tied
	 * to that one either -- the next time it is runnable, whichever
	 * cpu looks next takes it again.
	 *
	 * There used to be a least-loaded scan here, plus a rule
	 * pinning drivers to the boot cpu. Both are gone with the
	 * per-cpu queues they served. Placement at spawn is a guess
	 * made before the proc has done anything, and with p->home
	 * never reassigned it was a guess that lasted forever: procs
	 * spawned during boot were all placed when the machine had one
	 * cpu, so they stayed on it no matter what the other cpus were
	 * doing.
	 *
	 * p->home survives as a record of where it last RAN, set by
	 * run_proc, which is plan 9's `affinity` rather than a
	 * placement. Nothing reads it to make a decision today; it is
	 * there because "which cpu is this actually running on" is the
	 * question the smp tests ask, and because soft affinity, if it
	 * is ever wanted, is a use of exactly this field (port/proc.c's
	 * runproc, whose first pass prefers a proc that last ran here
	 * and whose second takes anything).
	 */
	p->home = 0;

	/* before lua_newstate, which allocates through kalloc, which
	 * reaches this proc's heap -- and, where there is one cpu, every
	 * other proc's too. See the comment at shared_heap.
	 */
	if (NCPU > 1) {
		p->heap = luaheap_new(&kalloc_ops, 0);
	} else {
		if (!shared_heap)
			shared_heap = luaheap_new(&kalloc_ops, 0);
		p->heap = shared_heap;
	}
	if (!p->heap)
		return -1;
	p->L = lua_newstate(kalloc, p);
	if (!p->L)
		return -1;

	/* how far the heap may grow past what is live before the next
	 * cycle. Lua's 200 means it doubles, which on a board with a few
	 * hundred KB is most of the machine spent on garbage that has
	 * already been collected once.
	 */
	lua_gc(p->L, LUA_GCINC, GCPAUSE, 0, 0);
	/* stash the proc pointer where the kernel api finds it (self()).
	 * set before the thread is created so lua_newthread copies it into
	 * the coroutine's extra space too.
	 */
	/* the whole record, not just the pointer: the links are copied
	 * into every coroutine from here, so they have to start empty
	 */
	memset(lua_getextraspace(p->L), 0, LUA_EXTRASPACE);
	((struct kextra *)lua_getextraspace(p->L))->p = p;
	p->id = nextpid++;	/* unique forever; slots recycle, pids don't */
	{
		/* lua chunknames conventionally lead with '=' (shown as-is)
		 * or '@' (a file); strip that marker for display purposes.
		 */
		const char *nm = chunkname;

		if (nm && (*nm == '=' || *nm == '@'))
			nm++;
		snprintf(p->name, sizeof p->name, "%s", nm ? nm : "?");
	}
	luaL_openlibs(p->L);

	/* self port = right handle 0 */
	struct kport *port = port_new();

	if (!port || right_new(p, port, 1) != 0) {
		if (port)
			port->used = 0;	/* no rights were taken */
		proc_freestate(p);
		return -1;
	}

	/* register the los.* modules in package.preload so chunks pull in
	 * the layers they need with an explicit require -- no globals, no
	 * disk search. los.sys and los.efi are C openers; los.thread is the
	 * lua runtime, loaded from disk once and preloaded (not auto-run).
	 */
	lua_getglobal(p->L, "package");
	lua_getfield(p->L, -1, "preload");

	lua_pushcfunction(p->L, los_sys_open);
	lua_setfield(p->L, -2, "los.sys");

	lua_pushcfunction(p->L, luaopen_los_efi);
	lua_setfield(p->L, -2, "los.efi");

	/* crypto.native (src/native.c): chacha20, poly1305, sha-256,
	 * sha-512 and aes. Ambient, unlike everything below, and the
	 * distinction is the one this file already draws for sys.send:
	 * authority is an ARGUMENT here, not the function. It computes on
	 * a key the caller supplies and does nothing for a caller that has
	 * not got one -- so there is nothing to attenuate and no owner to
	 * be the only one. Contrast los.platform.rng, where the raw draw
	 * IS the capability.
	 *
	 * src/native.c is a VERBATIM copy of the ssh tree's src/native.c
	 * -- the host tree is where these are developed and where the RFC
	 * vectors run against both the C and the Lua implementations, which
	 * is where a disagreement would be caught. Keeping it byte for byte
	 * identical makes the sync a cp and the check a diff; the previous
	 * arrangement hand-ported a subset and had already diverged.
	 *
	 * The Lua module name is ours rather than upstream's, because
	 * lua-os's tree puts these at crypto.* where the host tree has
	 * ssh.crypto.*. The C symbol keeps its upstream name: what a module
	 * is called and what its opener is called are independent, which is
	 * exactly what lets the file be copied untouched.
	 */
	lua_pushcfunction(p->L, luaopen_ssh_crypto_native);
	lua_setfield(p->L, -2, "crypto.native");

	/* gefs.native (src/gefs_native.c): metrohash64, which lib/gefs
	 * checksums every block with. Ambient for the same reason as the
	 * two around it -- a pure function of the string handed to it,
	 * reaching nothing -- and lib/gefs/hash.lua picks it up on its own
	 * if it is there, falling back to its own Lua otherwise.
	 */
	lua_pushcfunction(p->L, luaopen_gefs_native);
	lua_setfield(p->L, -2, "gefs.native");

	/* los.inet (src/inet.c), ambient for the same reason as the one
	 * above: the internet checksum is arithmetic on a string the
	 * caller already has, and it reaches nothing. Withholding it would
	 * not withhold anything -- lib/ip4.lua keeps the same function in
	 * Lua and falls back to it, more slowly, with the same answer.
	 */
	lua_pushcfunction(p->L, luaopen_los_inet);
	lua_setfield(p->L, -2, "los.inet");

	/* los.crc (src/crc.c), ambient on the same argument: two check
	 * polynomials over a string the caller already has, reaching
	 * nothing. lib/zmodem.lua has both in Lua and falls back to them.
	 */
	lua_pushcfunction(p->L, luaopen_los_crc);
	lua_setfield(p->L, -2, "los.crc");

	/* los.rom: the embedded set as data, ambient for the same reason.
	 * require() already reads these bytes in every proc through
	 * luaL_loadfile -- below the lua-level io stripping -- so what
	 * this adds is the ability to list them, and to read one without
	 * executing it. That is what lets a namespace be mounted
	 * read-only over the image with no server behind it, which is the
	 * only way an unprivileged proc on this platform can find a
	 * program at all.
	 */
	lua_pushcfunction(p->L, luaopen_los_rom);
	lua_setfield(p->L, -2, "los.rom");

	/* los.font (src/font.c), ambient on the same argument as the three
	 * above: glyphs are data, not a device. render() rasterises a
	 * string the caller already has into a pixel rectangle and reaches
	 * nothing -- the authority to put those pixels on a screen is
	 * los.platform.fb, which is the owned capability. A framebuffer
	 * console (lib/fbcons.lua) is one renderer plus that one right.
	 */
	lua_pushcfunction(p->L, luaopen_los_font);
	lua_setfield(p->L, -2, "los.font");
	/* los.fs is the whole of raw ESP access -- enumeration, metadata
	 * and file data. it is registered for exactly two procs: the esp
	 * server task, which serves the disk to everyone else over a port
	 * (lib/espsrv.lua), and proc 0, which has to read the esp to
	 * bootstrap before that mount exists. every other proc reaches
	 * files through a mount, which is a right rather than a reference.
	 */
	if (priv == PRIV_ESP || priv == PRIV_BOOT) {
		lua_pushcfunction(p->L, luaopen_los_fs);
		lua_setfield(p->L, -2, "los.fs");
	}

	/* los.platform.{cons,wire,power} are each registered ONLY for
	 * their one owning task -- not gated by a runtime check, simply
	 * absent from package.preload everywhere else, so there is no
	 * check to get wrong: the function isn't reachable to call.
	 */
	switch (priv) {
	case PRIV_CONS:
		lua_pushcfunction(p->L, luaopen_los_platform_cons);
		lua_setfield(p->L, -2, "los.platform.cons");
		break;
	case PRIV_WIRE:
		lua_pushcfunction(p->L, luaopen_los_platform_wire);
		lua_setfield(p->L, -2, "los.platform.wire");
		break;
	case PRIV_POWER:
		lua_pushcfunction(p->L, luaopen_los_platform_power);
		lua_setfield(p->L, -2, "los.platform.power");
		break;
	case PRIV_P9:
		lua_pushcfunction(p->L, luaopen_los_platform_p9);
		lua_setfield(p->L, -2, "los.platform.p9");
		break;
	case PRIV_ETH:
		lua_pushcfunction(p->L, luaopen_los_platform_eth);
		lua_setfield(p->L, -2, "los.platform.eth");
		/* the radio is one device: whoever moves its frames is
		 * whoever joins networks with it, as plan 9's ether is
		 * both. A no-op table on a platform whose NIC has nothing
		 * to associate with.
		 */
		lua_pushcfunction(p->L, luaopen_los_platform_wifi);
		lua_setfield(p->L, -2, "los.platform.wifi");
		break;
	case PRIV_BLK:
		lua_pushcfunction(p->L, luaopen_los_platform_blk);
		lua_setfield(p->L, -2, "los.platform.blk");
		break;
	case PRIV_FLASH:
		lua_pushcfunction(p->L, luaopen_los_platform_flash);
		lua_setfield(p->L, -2, "los.platform.flash");
		break;
	case PRIV_FB:
		lua_pushcfunction(p->L, luaopen_los_platform_fb);
		lua_setfield(p->L, -2, "los.platform.fb");
		break;
	}

	lua_pushcfunction(p->L, los_thread_open);
	lua_setfield(p->L, -2, "los.thread");

	lua_pop(p->L, 2);	/* preload, package */

	/* ninep (lib/ninep.lua) is found via plain require("ninep") --
	 * LUA_PATH search, ordinary fopen() -- same as any other module.
	 * it used to need a preload workaround here because reading was
	 * disk-gated; now that read is ambient (see stdio.c's fopen),
	 * that workaround is gone and require() just works.
	 */

	/* every proc EXCEPT proc 0 loses the file half of io, and loadfile
	 * and dofile with it.
	 *
	 * lib/nsio.lua puts io.open back, resolving through this proc's
	 * namespace -- so a proc that was given one reaches exactly what
	 * was mounted for it, and a proc that was given none has no way to
	 * open a file at all. that is the whole point: the namespace stops
	 * being advisory and starts being the boundary.
	 *
	 * removing the reference is the mechanism, not a check inside it.
	 * a check exists in every proc's C surface and is one bug away from
	 * everything; a function that is not there cannot be called wrong.
	 * same rule as los.platform.* (see AGENTS.md).
	 *
	 * io.write, io.read, print, stdout and stderr STAY. they are the
	 * console, not files -- a device we have no namespace entry for
	 * yet. see lib/nsio.lua on that seam.
	 *
	 * proc 0 keeps them because it is where the raw ESP reaches and
	 * where the root namespace is built; it has no namespace to be
	 * confined to until it has made one.
	 */
	if (priv != PRIV_BOOT) {
		/* referencing "io" here also FORCES the lazy load, so the
		 * table exists and is stripped rather than being created
		 * fresh (and whole) at first use.
		 */
		lua_getglobal(p->L, "io");
		kernel_strip_io(p->L);
		lua_pop(p->L, 1);

		lua_getglobal(p->L, "debug");
		kernel_strip_debug(p->L);
		lua_pop(p->L, 1);

		/* both load a chunk straight off the disk, which is the same
		 * hole wearing a different name
		 */
		lua_pushnil(p->L);
		lua_setglobal(p->L, "loadfile");
		lua_pushnil(p->L);
		lua_setglobal(p->L, "dofile");
	}

	p->co = lua_newthread(p->L);
	luaL_ref(p->L, LUA_REGISTRYINDEX);	/* anchor the thread */

	int rc;

	if (is_file)
		rc = luaL_loadfile(p->co, code);
	else
		rc = luaL_loadbuffer(p->co, code, codelen, chunkname);
	if (rc != LUA_OK) {
		kputs("proc load error: ");
		kputs(lua_tostring(p->co, -1));
		kputs("\n");
		right_drop(&p->rights[0]);
		proc_freestate(p);
		return -1;
	}

	/* the lua runtime (los.thread) is a preloaded module now, pulled in
	 * on demand by require("los.thread") -- no auto-run bootstrap.
	 */
	lua_sethook(p->co, preempt_hook, proc_hookmask(p), p->reductions);
	p->priv = priv;
	p->mem_limit = mem_limit;
	p->weight = 1;
	p->cputime = 0;
	p->cpu = 0;
	p->pri = 0;
	p->resumed = 0;
	p->lastupdate = uptime_ms();
	p->lastcpu = 0;
	p->exitcode = 0;
	p->exitmsg[0] = 0;
	SLIST_INIT(&p->waiters);
	p->onq = 0;
	p->pri = 0;
	make_ready(p);
	nlive++;
	return p->id;
}

/* build and deliver an exit notification: {exit=pid, normal=bool,
 * reason=string?, broke=true?} to the watcher's self port.
 *
 * broke=true is what makes a plain sys.monitor into linux's
 * core_pattern handler: the notification arrives while the corpse is
 * still held, so a watcher that cares can sys.stack the pid it was just
 * told about and sys.reap it when done. one flag on a message that was
 * already being sent, rather than a second notification mechanism.
 */
static void
/* caller holds ipclock: reached from proc_detach, which has it, and
 * from the noproc path above, which takes it. Locking here as well is
 * what hung every test that tears a proc down with a watcher
 * attached -- which is every test, at poweroff.
 */
notify_exit(struct kproc *watcher, int pid, const char *reason, int status,
    const char *exitmsg, int broke)
{
	struct wbuf w = { 0 };
	unsigned int npairs = 3;
	lua_Integer id = pid;
	lua_Integer st = status;

	if (reason)
		npairs++;
	if (exitmsg && exitmsg[0])
		npairs++;
	if (broke)
		npairs++;

	if (wbyte(&w, 'B') || wput(&w, &npairs, 4))
		goto fail;

	unsigned int klen = 4;

	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "exit", 4) ||
	    wbyte(&w, 'I') || wput(&w, &id, sizeof id))
		goto fail;

	klen = 6;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "normal", 6) ||
	    wbyte(&w, reason ? 'F' : 'T'))
		goto fail;

	klen = 6;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "status", 6) ||
	    wbyte(&w, 'I') || wput(&w, &st, sizeof st))
		goto fail;

	if (exitmsg && exitmsg[0]) {
		unsigned int mlen = strlen(exitmsg);

		klen = 7;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "exitmsg", 7) || wbyte(&w, 'S') ||
		    wput(&w, &mlen, 4) || wput(&w, exitmsg, mlen))
			goto fail;
	}

	if (reason) {
		unsigned int rlen = strlen(reason);

		if (rlen > 200)
			rlen = 200;
		klen = 6;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "reason", 6) || wbyte(&w, 'S') ||
		    wput(&w, &rlen, 4) || wput(&w, reason, rlen))
			goto fail;
	}
	if (broke) {
		klen = 5;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "broke", 5) || wbyte(&w, 'T'))
			goto fail;
	}
	/* no rights in an exit notice, so a refusal means only that the
	 * buffer comes back here to be freed.
	 */
	if (port_push_owned(watcher->rights[0].port, w.p, w.len, 0, 0, 0))
		free(w.p);
	return;
fail:
	free(w.p);
}

/* everything dying does except freeing the state.
 *
 * the split exists for BROKE: a corpse must stop being part of the
 * machine the instant it dies -- off the run queue, holding no rights,
 * with its monitors already told -- and only then linger. deferring any
 * of that until the reaper ran would make a corpse a hazard rather than
 * a record. a parent blocked in sys.monitor would wait on a proc that is
 * never coming back, and a broke fileserver would hold its ports open
 * and wedge every client instead of failing them.
 *
 * the deferred half is only lua_close, and only the __gc finalizers care
 * that the rights are already gone. they are written to tolerate it:
 * lib/mnt.lua's fid and session finalizers wrap the send and the close
 * in pcall, and src/dirs.c's is idempotent by construction. a finalizer
 * running against a released right fails and is swallowed, exactly as it
 * does for a handle closed by hand.
 */
static void
proc_detach(struct kproc *p, const char *why, const char *reason, int broke)
{
	wait_clear(p);
	proc_unqueue(p);
	nlive--;

	/* release every right this proc held; ports lose refs, orphaned
	 * queues flush, unreferenced ports free
	 */
	for (int i = 0; i < MAXRIGHTS; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used)
			right_drop(r);
	}
	free(p->xrights);
	p->xrights = 0;

	/* free the named-grant list. the rights it named were dropped in the
	 * loop above -- a grant is a right plus a name -- so only the list
	 * nodes remain to release.
	 */
	while (!SLIST_EMPTY(&p->grants)) {
		struct grant *g = SLIST_FIRST(&p->grants);

		SLIST_REMOVE_HEAD(&p->grants, e);
		free(g);
	}

	/* erlang-style DOWN: tell the watchers */
	for (int i = 0; i < p->nwatch; i++) {
		struct kproc *w = find_proc(p->watchers[i]);

		if (w)
			notify_exit(w, p->id, why ? reason : 0,
			    why ? -1 : p->exitcode,
			    why ? 0 : p->exitmsg, broke);
	}
	p->nwatch = 0;
}

/* log line and copied reason are shared by both exits; the reason
 * usually points into the lua state, which one path is about to close
 * and the other will close later, so it is copied either way.
 */
static void
proc_logdeath(struct kproc *p, const char *why, char *reason, size_t n)
{
	char buf[256];

	if (!why)
		return;
	snprintf(reason, n, "%s", why);
	snprintf(buf, sizeof buf, "proc %d (%s) died: %s", p->id, p->name,
	    reason);
	kernel_log(buf);
}

static void
proc_kill(struct kproc *p, const char *why)
{
	char reason[224];

	proc_logdeath(p, why, reason, sizeof reason);

	/* the lock goes around proc_detach and not around
	 * proc_freestate, which calls lua_close, which runs this proc's
	 * __gc finalizers -- arbitrary lua, and the reason those
	 * finalizers exist is to clunk handles, so they reach api_close
	 * and would take this lock while we held it.
	 */
	proc_freestate(p);

	ipclock_enter();
	proc_detach(p, why, reason, 0);
	p->status = DEAD;
	ipclock_leave();
}

/* how many corpses may be held at once.
 *
 * each one is a whole lua_State parked in the shared heap -- tens of
 * kilobytes that no live proc can use -- so this is a cache of recent
 * deaths, not a graveyard. breaking past the cap reaps the oldest, on
 * the theory that the death you are looking into is the one that just
 * happened.
 */
#define MAXBROKE	2

static void
proc_reap(struct kproc *p)
{
	if (p->status != BROKE)
		return;
	proc_freestate(p);
	p->status = DEAD;
}

static void
proc_break(struct kproc *p, const char *why)
{
	char reason[224];
	struct kproc *oldest = 0;
	int n = 0;

	proc_logdeath(p, why, reason, sizeof reason);

	ipclock_enter();
	proc_detach(p, why, reason, 1);
	p->status = BROKE;
	p->brokeseq = ++brokeseq;

	for (int i = 0; i < prochigh; i++) {
		struct kproc *q = procv[i];

		if (!q || q->status != BROKE)
			continue;
		n++;
		if (!oldest || q->brokeseq < oldest->brokeseq)
			oldest = q;
	}
	ipclock_leave();
	/* outside: proc_reap frees the corpse's state, which is
	 * lua_close again and the same finalizer problem.
	 */
	if (n > MAXBROKE && oldest)
		proc_reap(oldest);
}

/* ---- serial pump (9p wire on com2) ---- */

extern void uart_init(void);
extern int uart_rx(void);
extern void uart_poll(void);	/* drain the hw fifo into the rx ring */

static struct kport *serport;

static int
pump_serial(void)
{
	unsigned char buf[5 + 256];
	unsigned int n = 0;
	int c;

	/* the console claimed these bytes; pump_keyboard takes them
	 * instead. One uart cannot feed two readers, and taking them here
	 * first is exactly how the console got no input at all.
	 */
	if (platform_console_input())
		return 0;

	while (n < 256 && (c = uart_rx()) >= 0)
		buf[5 + n++] = (unsigned char)c;
	if (n == 0)
		return 0;
	/* serialized string message: tag, u32 len, bytes */
	buf[0] = 'S';
	memcpy(buf + 1, &n, 4);
	ipclock_enter();
	port_push(serport, buf, 5 + n, 0, 0);
	ipclock_leave();
	return 1;
}

/* ---- eth pump ---- */

/* the eth wakeup: push only when a device interrupt has been taken
 * since the last look.
 *
 * Coalesced by the emptiness check, so a burst of frames is one wakeup
 * rather than one per frame -- the task drains what is there when it
 * runs, and a second ping while the first is unread would tell it
 * nothing new.
 */
static void
pump_eth(void)
{
	static unsigned long seen;
	unsigned long now = platform_dev_irqs();

	if (now == seen)
		return;
	seen = now;
	/* "N" is a serialized nil, which is what this has to be: a port
	 * carries serialized values, and the
	 * receiving task deserializes whatever arrives. A byte chosen to
	 * be mnemonic instead of valid ("E", the first try) reaches the
	 * task as a corrupt message and kills it. The wakeup carries no
	 * information anyway -- the frames are still in the device's
	 * queue, and this says only "ask again".
	 */
	ipclock_enter();
	if (have_eth && ethport && !ethport->head)
		port_push(ethport, (const unsigned char *)"N", 1, 0, 0);
	ipclock_leave();
}

/* ---- keyboard pump ---- */

/* the firmware's serial console reports the arrow/navigation keys and the
 * Escape key as ScanCodes with UnicodeChar 0, having already parsed the
 * ANSI sequences a byte terminal sends. A full-screen program (bin/vi.lua)
 * wants those bytes, so turn the ScanCodes back into the sequences -- the
 * exact inverse of what the firmware did, so vi sees what it would see on
 * a raw serial line. Values are the UEFI spec's (table "EFI Scan Codes");
 * SCAN_DELETE (physical Backspace under OVMF) is handled separately below
 * and deliberately absent here. Returns 0 for a ScanCode with no mapping,
 * including the 0 that a raw serial shim (microvm) always reports.
 */
static const char *
scancode_seq(unsigned scan)
{
	switch (scan) {
	case 0x17: return "\033";	/* Esc */
	case 0x01: return "\033[A";	/* Up */
	case 0x02: return "\033[B";	/* Down */
	case 0x03: return "\033[C";	/* Right */
	case 0x04: return "\033[D";	/* Left */
	case 0x05: return "\033[H";	/* Home */
	case 0x06: return "\033[F";	/* End */
	case 0x09: return "\033[5~";	/* PageUp */
	case 0x0a: return "\033[6~";	/* PageDown */
	case 0x07: return "\033[2~";	/* Insert */
	default:   return 0;
	}
}

/* drain the second terminal's keyboard into its own port.
 *
 * The same shape as pump_keyboard below, and deliberately not the same
 * port: this machine's console is a serial line, and a panel with a
 * keyboard is a second terminal rather than a second way into the
 * first.
 */
static void
pump_devkbd(void)
{
	int c;

	if (!devkbdport)
		return;
	while ((c = platform_kbd_read()) >= 0) {
		/* serialized one-char string, as pump_keyboard sends: a
		 * port carries serialized values and the reader
		 * deserializes whatever arrives.
		 */
		unsigned char msg[6] = { 'S', 1, 0, 0, 0, 0 };

		msg[5] = (unsigned char)c;
		port_push(devkbdport, msg, sizeof msg, 0, 0);
	}
}

static void
pump_keyboard(void)
{
	ipclock_enter();
	EFI_INPUT_KEY key;

	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_SUCCESS) {
		/* serialized one-char string: tag, u32 len, byte */
		unsigned char msg[6] = { 'S', 1, 0, 0, 0, 0 };

		/* the physical Backspace key arrives as ScanCode=SCAN_DELETE,
		 * UnicodeChar=0 under OVMF (confirmed by direct trace), not
		 * as CHAR_BACKSPACE -- map it to DEL (0x7f), which cons.lua's
		 * readline already treats the same as Ctrl-H/0x08.
		 */
		if (key.ScanCode == SCAN_DELETE && key.UnicodeChar == 0) {
			msg[5] = 0x7f;
			port_push(kbdport, msg, sizeof msg, 0, 0);
			continue;
		}
		/* a non-unicode key: an arrow, Escape and the like. Deliver the
		 * ANSI sequence one byte per message, exactly as a raw serial
		 * line would -- vi's readkey reads Esc, then the rest.
		 */
		if (key.UnicodeChar == 0) {
			const char *seq = scancode_seq(key.ScanCode);

			for (; seq && *seq; seq++) {
				msg[5] = (unsigned char)*seq;
				port_push(kbdport, msg, sizeof msg, 0, 0);
			}
			continue;
		}
		if (key.UnicodeChar >= 0x80)
			continue;
		msg[5] = (unsigned char)key.UnicodeChar;
		port_push(kbdport, msg, sizeof msg, 0, 0);
	}
	ipclock_leave();
}

/* ---- kernel ---- */

int
kernel_init(void)
{
	calibrate_reductions();	/* kernel_clock_init already ran in efi_main */
	rq_init();		/* before any proc exists to be dispatched */
	uart_init();
	/* boot, before any proc exists: the lock is uncontended and is
	 * taken for the contract rather than for the contention.
	 */
	ipclock_enter();
	kbdport = port_new();
	devkbdport = platform_have_kbd() ? port_new() : 0;
	serport = port_new();
	diskport = port_new();
	ethport = port_new();
	schedport = port_new();
	ipclock_leave();
	if (!kbdport || !serport || !diskport || !schedport || !ethport)
		return -1;
	/* kernel refs: the pumps (and, for diskport/schedport, the kernel
	 * itself) hold these ports forever
	 */
	kbdport->nrights++;
	if (devkbdport)
		devkbdport->nrights++;
	serport->nrights++;
	diskport->nrights++;
	ethport->nrights++;
	schedport->nrights++;

	/* soft-fail: no NIC (real hardware, or qemu -net none) just means
	 * no eth task gets spawned later, same as any other optional
	 * boot-time resource.
	 *
	 * platform_have_eth() on efi calls DisconnectController, which
	 * unbinds the firmware's MNP/IP4/TCP4/UDP4 from the card. It has
	 * to: SNP has one receive queue and no fan-out, so a firmware
	 * stack left bound would eat frames we never see. There is nothing
	 * left to fall back TO -- one stack, task/eth.lua under
	 * task/ip.lua under task/tcp4.lua, on every platform.
	 */
	have_eth = platform_have_eth();
	have_p9 = platform_have_p9();
	have_fb = platform_have_fb();
	have_blk = platform_have_blk();
	have_flash = platform_have_flash();
	have_wire = platform_have_wire();
	have_esp = platform_have_esp();
	return 0;
}

/* spawn a privileged driver task and grant it whatever raw device
 * right it needs directly (handle 1, right after the universal
 * self-port at 0). returns its pid, or -1 with a boot warning; the
 * corresponding resource is simply unreachable for the rest of that
 * boot if its task fails to start.
 */
static int
spawn_driver(const char *path, const char *chunkname, int priv,
    struct kport *devport, int devrecv, const char *what)
{
	/* caller holds ipclock: spawn_init calls this in a loop and
	 * holds it across all of them.
	 */
	int pid = proc_new(path, 0, chunkname, 1, 0, 0, priv);
	char buf[160];

	if (pid < 0) {
		snprintf(buf, sizeof buf,
		    "%s: FAILED to start; %s unavailable this boot",
		    chunkname + 1, what);
		kernel_log(buf);
		return -1;
	}
	if (devport) {
		struct kproc *p = find_proc(pid);

		if (p)
			right_new(p, devport, devrecv);
	}

	/* announce what attached, the way a bsd announces its devices.
	 * these tasks ARE our device layer -- one proc per raw right -- and
	 * the pid is the part you cannot recover later without a shell,
	 * which is exactly when you have not got one.
	 */
	snprintf(buf, sizeof buf, "%s: pid %d, %s", chunkname + 1, pid, what);
	kernel_log(buf);
	return pid;
}

/* spawn the boot payload (init.lua or an injected fw_cfg test buffer)
 * and hand it send-rights to cons/wire/power plus the disk capability
 * -- the full boot-level grant, same shape as the old KBD/SERIAL/CONIO
 * grant it replaces. ordinary sys.spawn children still get none of
 * this by default; only the boot payload (analogous to pid 1 on a
 * unix system) starts this privileged.
 */
/* one row per driver task the boot payload gets a right to. "enabled"
 * is decided before this table is built (have_net/have_udp come from
 * the net_init() probe in kernel_init()) -- this is still a one-shot,
 * boot-time, C-side table, not a runtime bus/match-and-attach
 * registry. disk and sched aren't in it: there's no lua owner task for
 * either, they're bare capability ports granted to init directly.
 */
struct driver_desc {
	const char *path;
	const char *chunkname;
	int priv;
	struct kport *devport;
	int devrecv;
	const char *what;
	int enabled;
	const char *capname;	/* what sys.granted() calls it */

	/* another driver this one cannot work without, by capname.
	 *
	 * The device tasks each own a raw right and need nothing from each
	 * other, but a task can also be built on one of them: the ip stack
	 * is a proc whose device is the eth task. Naming it here rather
	 * than passing the right in a first message keeps a task's
	 * capabilities in one place -- sys.granted() -- however it got
	 * them, and means a task whose dependency failed to start is
	 * simply a task with nothing under it, which it can say so about.
	 */
	const char *needs;

	/* this task needs to draw random bytes (los.platform.rng).
	 *
	 * Only the boot proc gets that module by default, which is the
	 * right default -- the raw draw IS the capability, as the comment
	 * on luaopen_ssh_crypto_native puts it, so it goes to as few procs
	 * as possible. But tcp cannot do without one: RFC 6528 requires an
	 * initial sequence number that is neither a counter nor derivable
	 * from another connection's, because an off-path attacker who can
	 * guess it can inject into the stream. lib/tcb.lua deliberately
	 * refuses to invent one -- it has no clock and no secret -- so the
	 * task that owns the connections has to be able to.
	 */
	unsigned rng;
};

static int
spawn_init(const char *code, size_t len, int is_file)
{
	struct driver_desc drivers[] = {
		{ .path = "/task/cons.lua", .chunkname = "=cons",
		  .priv = PRIV_CONS, .devport = kbdport, .devrecv = 1,
		  .what = "console", .enabled = 1, .capname = "cons" },
		{ .path = "/task/wire.lua", .chunkname = "=wire",
		  .priv = PRIV_WIRE, .devport = serport, .devrecv = 1,
		  .what = "the 9p wire", .enabled = have_wire,
		  .capname = "wire" },
		/* the esp server: the only proc that reaches the disk
		 * directly. it gets diskport at handle 1, so writes are
		 * possible here and nowhere else.
		 */
		{ .path = "/task/espsrv.lua", .chunkname = "=esp",
		  .priv = PRIV_ESP, .devport = diskport, .devrecv = 0,
		  .what = "the esp filesystem", .enabled = have_esp,
		  .capname = "esp" },
		{ .path = "/task/power.lua", .chunkname = "=power",
		  .priv = PRIV_POWER, .devport = 0, .devrecv = 0,
		  .what = "reset/stall", .enabled = 1, .capname = "power" },
		/* the virtio-9p mount source: the only proc with
		 * los.platform.p9, re-serving it over a port as an
		 * ordinary dev backend (lib/p9fs.lua) so mnt.lua can mount
		 * it exactly like the esp -- no second namespace mechanism,
		 * just another srv.lua backend. disabled on efi today
		 * because that driver only speaks virtio-MMIO, not because
		 * virtio-9p can't exist under EFI -- see platform_have_p9's
		 * own comment in platform.h.
		 */
		{ .path = "/task/p9srv.lua", .chunkname = "=p9srv",
		  .priv = PRIV_P9, .devport = 0, .devrecv = 0,
		  .what = "the virtio-9p filesystem", .enabled = have_p9,
		  .capname = "p9" },
		/* the block device: the only proc with los.platform.blk,
		 * re-serving it over a port as a dev backend
		 * (lib/blkfs.lua) the same way p9srv does. Unlike every
		 * other backend here what it serves is not a filesystem --
		 * it is one file, /data, that IS the disk. Whatever
		 * eventually reads a filesystem out of those bytes mounts
		 * this and needs to know nothing about virtio, which is the
		 * point of putting the seam here.
		 *
		 * No devport: nothing is routed to this device's interrupt
		 * line, so there is no wakeup to deliver. blk.read and
		 * blk.write yield and re-poll instead, which is what
		 * virtio-9p has always done.
		 */
		{ .path = "/task/blksrv.lua", .chunkname = "=blksrv",
		  .priv = PRIV_BLK, .devport = 0, .devrecv = 0,
		  .what = "the block device", .enabled = have_blk,
		  .capname = "blk" },
		/* the writable flash partition, served the same way and by
		 * the same task: one file, /data, that is the partition.
		 * Two procs run task/blksrv.lua on a board with both, each
		 * holding the capability for one device, so neither can
		 * reach the other's sectors. Which one a proc got is not a
		 * question it can ask -- it holds a right, and the right is
		 * the answer.
		 */
		{ .path = "/task/blksrv.lua", .chunkname = "=flashsrv",
		  .priv = PRIV_FLASH, .devport = 0, .devrecv = 0,
		  .what = "the flash partition", .enabled = have_flash,
		  .capname = "flash" },
		/* raw ethernet frames, and the bottom of the whole stack.
		 * This task owns a wire and nothing more -- everything from
		 * arp upwards is Lua on the far side of its port. No NIC
		 * (real hardware, or qemu -net none) is the normal case
		 * rather than a boot failure, so it and everything needing
		 * it simply do not spawn.
		 */
		{ .path = "/task/eth.lua", .chunkname = "=eth",
		  .priv = PRIV_ETH, .devport = ethport, .devrecv = 1,
		  .what = "networking (raw ethernet)", .enabled = have_eth,
		  .capname = "eth" },
		/* the ipv4 stack: arp, ip, icmp and udp over the eth task
		 * above. Not a device owner -- it holds no raw right of its
		 * own, only a send right to eth -- but a task all the same,
		 * and one that must be running for the machine to be on a
		 * network at all rather than merely able to get onto one.
		 *
		 * After eth in this table because it is granted eth's port,
		 * and the loop below resolves that by looking backwards.
		 */
		{ .path = "/task/ip.lua", .chunkname = "=ip",
		  .priv = PRIV_NONE, .devport = 0, .devrecv = 0,
		  .what = "the ipv4 stack", .enabled = have_eth,
		  .capname = "ip", .needs = "eth" },
		/* tcp in lua, over the ip task. Its capname is "tcp"
		 * because that is the protocol name its clients ask for:
		 * lib/http.lua, lib/ssh, task/sshd.lua and task/webterm.lua
		 * are written against it and cannot tell what implements
		 * it. The firmware's own TCP4 used to answer to the same
		 * name on efi, which is how they came to run unchanged on
		 * both platforms; now this is the only thing that does.
		 */
		{ .path = "/task/tcp4.lua", .chunkname = "=tcp4",
		  .priv = PRIV_NONE, .devport = 0, .devrecv = 0,
		  .what = "networking (tcp)", .enabled = have_eth,
		  .capname = "tcp", .needs = "ip", .rng = 1 },
		/* the dhcp client, which is what gives the stack above an
		 * address and then keeps it.
		 */
		{ .path = "/task/dhcpd.lua", .chunkname = "=dhcpd",
		  .priv = PRIV_NONE, .devport = 0, .devrecv = 0,
		  .what = "dhcp", .enabled = have_eth,
		  .capname = "dhcpd", .needs = "ip" },
		/* the framebuffer. no devport: unlike the console or the
		 * wire there is nothing to poll -- a screen produces no
		 * events, and the input devices that go with one are
		 * already somebody else's capability. so this task only
		 * ever receives from procs holding a right to it.
		 */
		{ .path = "/task/fb.lua", .chunkname = "=fb",
		  .priv = PRIV_FB, .devport = 0, .devrecv = 0,
		  .what = "the framebuffer", .enabled = have_fb,
		  .capname = "fb" },
	};
	size_t ndrivers = sizeof drivers / sizeof drivers[0];
	int pids[sizeof drivers / sizeof drivers[0]];
	size_t i;

	/* one region over the whole of boot's proc and port creation.
	 * spawn_driver, proc_new and grant_named are all caller-holds,
	 * and holding it across the lot is free here: nothing else is
	 * running yet, and the alternative is acquiring and releasing
	 * once per driver for no benefit.
	 */
	ipclock_enter();
	for (i = 0; i < ndrivers; i++) {
		if (!drivers[i].enabled) {
			char skip[160];

			snprintf(skip, sizeof skip, "%s: not present, %s "
			    "unavailable this boot",
			    drivers[i].chunkname + 1, drivers[i].what);
			kernel_log(skip);
			pids[i] = -1;
			continue;
		}
		pids[i] = spawn_driver(drivers[i].path, drivers[i].chunkname,
		    drivers[i].priv, drivers[i].devport, drivers[i].devrecv,
		    drivers[i].what);

		/* the same grant the boot proc gets below, for the one task
		 * that asked for it. Narrow on purpose: this hands over
		 * los.platform.rng and nothing else -- virtio-9p is a
		 * separate decision behind PRIV_P9 -- and it is a no-op on
		 * efi, where the module does not exist.
		 */
		if (drivers[i].rng && pids[i] >= 0) {
			struct kproc *rp = find_proc(pids[i]);

			if (rp)
				platform_boot_extra_modules(rp->L);
		}
	}

	int pid = proc_new(code, len, "=init", is_file, 0, 0, PRIV_BOOT);

	if (pid < 0) {
		ipclock_leave();
		return pid;
	}

	struct kproc *p = find_proc(pid);

	/* platform_boot_extra_modules grants whatever raw device modules
	 * have no driver-task equivalent yet (microvm's los.platform.rng/
	 * p9 -- see src/platform/microvm/drivers.c); a no-op on efi.
	 */
	if (p)
		platform_boot_extra_modules(p->L);

	/* handles are allocated first-free, in this order, and reported
	 * by name through sys.granted(). nothing anywhere depends on the
	 * numbers: a driver that was disabled or failed to spawn simply
	 * doesn't appear in the mapping, and everything after it shifts
	 * down a slot harmlessly.
	 */
	/* a task that names another gets a send right to it, under the
	 * same name the boot proc knows it by. Done before the boot proc's
	 * own grants purely for reading order; the two are independent.
	 */
	for (i = 0; i < ndrivers; i++) {
		if (!drivers[i].needs || pids[i] < 0)
			continue;

		struct kproc *np = find_proc(pids[i]);

		for (size_t j = 0; j < ndrivers; j++) {
			if (pids[j] < 0 || !drivers[j].capname)
				continue;
			if (strcmp(drivers[j].capname, drivers[i].needs) != 0)
				continue;

			struct kproc *dep = find_proc(pids[j]);

			if (np && dep)
				grant_named(np, drivers[j].capname,
				    dep->rights[0].port, 0);
			break;
		}
	}

	for (i = 0; i < ndrivers; i++) {
		struct kproc *dp = pids[i] >= 0 ? find_proc(pids[i]) : 0;

		if (dp)
			grant_named(p, drivers[i].capname,
			    dp->rights[0].port, 0);
	}
	/* a receive right: whoever init hands this to IS the second
	 * terminal's keyboard, and there is only one of it.
	 */
	if (devkbdport)
		grant_named(p, "kbd", devkbdport, 1);
	grant_named(p, "disk", diskport, 0);
	grant_named(p, "sched", schedport, 0);
	ipclock_leave();
	return pid;
}

int
kernel_spawn_file(const char *path)
{
	return spawn_init(path, 0, 1);
}

int
kernel_spawn_buffer(const char *code, size_t len)
{
	return spawn_init(code, len, 0);
}

/* resume one READY proc, spending its whole WRR weight. returns 1 if it
 * ran at all, which is what tells kernel_run the machine is not idle.
 *
 * factored out of the dispatch loop so the handoff hint can dispatch a
 * proc out of slot order without duplicating any of this.
 */
/* exponentially-weighted average of the fraction of wall time this proc
 * spent running, in per-mille, from the TSC.
 *
 * an instruction count was tried instead and dropped: the preempt hook
 * fires every lua_gethookcount() instructions, so counting fires is an
 * exact reduction count -- but only for procs that REACH their period. a
 * proc that yields sooner registers zero, which is most IPC-bound work,
 * and lua exposes no way to read the partial countdown (L->hookcount is
 * internal; lua_gethookcount returns the configured period). exact
 * reductions would mean patching the VM, and vanilla lua is a pillar.
 * cycles have no floor, catch time spent in C too, and are what real
 * schedulers use.
 *
 * plan 9's updatecpu samples "was this proc running at the tick" and
 * decays from there, which suits a tick-driven kernel. ours resumes
 * procs for tens of microseconds at a time, far below the 1ms clock, so
 * sampling would read zero forever. we have measured cycles instead, so
 * the fraction is computed directly and then averaged.
 *
 * lazy on purpose: the decay is a closed form over the elapsed interval,
 * so a proc untouched for five seconds decays correctly in one call and
 * no periodic sweep is needed.
 */
static void
updatecpu(struct kproc *p)
{
	unsigned long long now = uptime_ms();
	unsigned long long n = now - p->lastupdate;

	/* below this the fraction is mostly quantisation noise */
	if (n < 10)
		return;

	unsigned long long used = p->cputime - p->lastcpu;
	unsigned long long window = n > SCHED_DECAY_MS ? SCHED_DECAY_MS : n;
	/* form the fraction straight from cycles rather than converting to
	 * whole milliseconds first. the intermediate truncation was
	 * harmless when this was only called on demand, with n in the
	 * hundreds of ms -- but the scheduler now calls it every lap, where
	 * n is ~15ms and losing up to 1ms per sample is a systematic 7%
	 * undercount. it read a spinning proc at 478 per-mille instead of
	 * 876.
	 */
	unsigned long long denom = n * (cyc_per_ms ? cyc_per_ms : 1);
	unsigned frac = denom ? (unsigned)((used * 1000) / denom) : 0;

	if (frac > 1000)
		frac = 1000;

	p->cpu = (unsigned)(((unsigned long long)p->cpu *
	    (SCHED_DECAY_MS - window) + (unsigned long long)frac * window) /
	    SCHED_DECAY_MS);
	p->lastupdate = now;
	p->lastcpu = p->cputime;
}

/* dynamic priority: inversely proportional to recent cpu use against an
 * equal share, clamped to the proc's static weight. straight from plan
 * 9's reprioritize, with weight playing basepri's part -- so
 * sys.set_priority stays the capability-gated POLICY knob and the kernel
 * computes the rest, which is the split we already had.
 *
 * a proc using exactly its share lands at its weight; a hog sinks toward
 * zero; one that has been starved has cpu near zero and clamps to the
 * top. nobody is demoted by a rule.
 */
static int
reprioritize(struct kproc *p, int nrunnable)
{
	updatecpu(p);

	if (nrunnable <= 0)
		nrunnable = 1;

	unsigned fair = 1000u / (unsigned)nrunnable;
	unsigned n = p->cpu ? p->cpu : 1;
	unsigned cap = (unsigned)p->weight * PRI_BASE;
	unsigned long long r = ((unsigned long long)fair * cap) / n;

	return (int)(r > cap ? cap : r);
}

/* mark a proc runnable and price it, which is plan 9's ready(): priority
 * is computed HERE rather than at dispatch, so the dispatcher only reads
 * an int. that keeps reprioritize off the hot path -- it now runs once
 * per wakeup instead of once per ready proc per lap.
 *
 * it also depends on updatecpu being sampling-independent, since wakeups
 * are irregular where laps were not. that is why the chunked decay above
 * had to come first.
 */
/* the two dispatch sets. runq holds procs still to run this lap, donq
 * those that have already had their turn; they swap at the end of a lap.
 */


/* the run queues: one pair for the machine, not one pair per cpu.
 *
 * Any cpu takes the next runnable proc from the same place, so a proc
 * is never stuck behind a busy cpu while another idles, and there is no
 * placement decision to make at spawn. That decision is the one that
 * cannot be made well: it is made before the proc has done anything,
 * and nothing revisits it.
 *
 * This is plan 9's arrangement -- port/proc.c's `Schedq runq[Nrq]` is
 * global there too -- rather than the per-cpu queues and work stealing
 * of OpenBSD's kern_sched.c. The usual argument for per-cpu queues is
 * keeping cpus off one lock on the hottest path, and that argument is
 * weak here: every send and every wakeup already passes through the
 * single ipc lock, held longer than anything done under this one. This
 * cannot become the bottleneck without that being one first.
 *
 * If it ever does contend, plan 9 has the next step as well: it locks
 * each priority queue separately rather than the whole set.
 *
 * `runq` is the lap in progress, `donq` what has already had a turn,
 * and dispatch_lap swaps them. schedlock guards both, and also every
 * cpu's current/idle/dispatching -- readers of those are always
 * deciding something about these queues at the same time.
 */
static struct lock schedlock = LOCK_INIT;
static struct rqset schedq[2];
static struct rqset *runq, *donq;

static void
rq_init(void)
{
	/* once, for the machine, before any proc exists. Nothing per
	 * cpu has to be set up, which is what lets a cpu join the
	 * scheduler at any point in the boot -- or never.
	 */
	for (int s = 0; s < 2; s++) {
		for (int i = 0; i < NRQ; i++)
			TAILQ_INIT(&schedq[s].q[i]);
		schedq[s].mask = 0;
		schedq[s].n = 0;
	}
	runq = &schedq[0];
	donq = &schedq[1];
}

static int
rq_bucket(int pri)
{
	int top = MAXWEIGHT * PRI_BASE;

	if (pri < 0)
		pri = 0;
	if (pri > top)
		pri = top;
	return pri * (NRQ - 1) / top;
}

static void
rq_add(struct rqset *set, struct kproc *p)
{
	int b = rq_bucket(p->pri);

	SCHED_ASSERT_LOCKED();
	TAILQ_INSERT_TAIL(&set->q[b], p, rqe);
	set->mask |= 1u << b;
	set->n++;
	p->onq = set;
}

static void
rq_del(struct kproc *p)
{
	struct rqset *set = p->onq;
	int b;

	SCHED_ASSERT_LOCKED();
	if (!set)
		return;
	b = rq_bucket(p->pri);
	TAILQ_REMOVE(&set->q[b], p, rqe);
	if (TAILQ_EMPTY(&set->q[b]))
		set->mask &= ~(1u << b);
	set->n--;
	p->onq = 0;
}

/* highest bucket first: this is where priority is consulted, and the only
 * place it is.
 */
static struct kproc *
rq_take_high(struct rqset *set)
{
	for (int b = NRQ - 1; b >= 0; b--)
		if (set->mask & (1u << b)) {
			struct kproc *p = TAILQ_FIRST(&set->q[b]);

			rq_del(p);
			return p;
		}
	return 0;
}

/* any of them, priority not consulted. phase two's guarantee must not
 * depend on the priority function being right, so it does not ask.
 */
static struct kproc *
rq_take_any(struct rqset *set)
{
	for (int b = 0; b < NRQ; b++)
		if (set->mask & (1u << b)) {
			struct kproc *p = TAILQ_FIRST(&set->q[b]);

			rq_del(p);
			return p;
		}
	return 0;
}

/* park a proc that is running: it goes to sleep on a port and stops
 * being runnable.
 *
 * Both halves need schedlock. The queues are one structure for the
 * machine, so rq_del touching them from a syscall while another cpu is
 * in dispatch_lap corrupts them, and `status` is what dispatch_lap
 * reads under that same lock to decide whether to requeue.
 *
 * The caller holds ipclock, and ipc -> sched is the allowed order.
 */
static void
proc_block(struct kproc *p)
{
	IPC_ASSERT_ANY();
	lock(&schedlock);
	p->status = BLOCKED;
	rq_del(p);
	unlock(&schedlock);
}

/* take a proc off whatever queue it is on, for a caller that is not
 * putting it to sleep -- proc_detach, where it is dying. Same reason
 * for the lock.
 */
static void
proc_unqueue(struct kproc *p)
{
	lock(&schedlock);
	rq_del(p);
	unlock(&schedlock);
}

static void
make_ready(struct kproc *p)
{
	/* caller holds some ipc bucket.
	 * CONTEXT: proc_new, wake_receivers, wake_senders.
	 *
	 * Some rather than all, because the two wakers hold only the
	 * bucket covering the port they woke on. Everything below is
	 * schedlock's business; what the ipc side has to guarantee is
	 * that the decision to wake p was made inside a region that
	 * still holds, and any bucket answers that.
	 */
	IPC_ASSERT_ANY();

	/* one lock, and no cpu to choose: whichever looks next takes
	 * it. Nested inside the ipc lock, which is the one nesting
	 * lock.h's order allows (ipc -> sched).
	 */
	lock(&schedlock);

	/* which queue p is already on, read under the lock: another cpu
	 * takes procs off these, so a read from outside can name a queue
	 * p has already left.
	 */
	struct rqset *keep = p->onq;

	/* p may be running right now on another cpu, which is a case
	 * that cannot arise on one cpu: there, the only proc running is
	 * the one doing the sending. Enqueueing it would put it on a
	 * bucket while that cpu's dispatch_lap still holds it, and
	 * dispatch_lap enqueues it again when the resume returns -- one
	 * proc on two buckets, and a run queue that no longer
	 * terminates.
	 *
	 * So leave it to the cpu running it. Marking it READY is
	 * enough: dispatch_lap requeues on exactly that, and it gives
	 * the proc back under this same lock, so one of the two always
	 * sees the other.
	 *
	 * The proc is asked rather than the cpus, for the reason in
	 * proc_running: a scan of cpu_at() misses an AP that is
	 * dispatching but not yet counted, and two cpus then take the
	 * same proc.
	 */
	if (p->oncpu) {
		p->status = READY;
		p->pri = reprioritize(p, count_runnable() + 1);
		unlock(&schedlock);
		return;
	}

	if (keep)
		rq_del(p);		/* pri is about to change; rebucket */
	p->status = READY;
	/* +1 because p has just been taken off its bucket and so is not in
	 * the count, but it is runnable and the fair share has to include it
	 */
	p->pri = reprioritize(p, count_runnable() + 1);
	/* a proc already waiting its turn keeps the lap it was in. one
	 * arriving fresh joins the current lap, which is how a mid-lap
	 * wakeup can still get a turn this lap -- if the lap's remaining
	 * budget reaches it, and the next lap's opening runq if not.
	 */
	rq_add(keep ? keep : runq, p);

	/* somebody has to look, so wake one sleeper. One, not all: the
	 * others would find the queue empty and go back to sleep having
	 * cost an ipi each, and if there is more work than one cpu's
	 * worth, the next make_ready wakes the next one.
	 *
	 * Chosen under the lock, so a cpu cannot have decided to sleep
	 * between this test and the queue it would have found empty --
	 * the idle path sets the flag with this same lock held, and for
	 * that reason.
	 */
	unsigned wake = ~0u;

	for (unsigned i = 0; i < platform_ncpu(); i++) {
		struct cpu *c = cpu_at(i);

		if (c && c->idle && c != cpu_self()) {
			wake = i;
			break;
		}
	}

	unlock(&schedlock);

	if (wake != ~0u)
		platform_wake_cpu(wake);
}

static int
count_runnable(void)
{
	/* a proc being resumed is on neither set -- dispatch takes it
	 * off before running it and puts it back after -- so the ones
	 * in hand have to be counted here, or a proc asking about its
	 * own fair share leaves itself out of the divisor. With one
	 * queue for the machine that means every cpu's, not one's.
	 */
	int running = 0;

	for (unsigned i = 0; i < platform_ncpu(); i++) {
		struct cpu *c = cpu_at(i);

		if (c && c->current && c->current->status == READY &&
		    !c->current->onq)
			running++;
	}
	return runq->n + donq->n + running;
}

/* run the proc's sys.atexit handlers, LIFO, on the main state -- p->co
 * has finished, but its registry is p->L's, so the list is still here.
 * self() reads the handler state's extraspace, so the kernel api resolves
 * without help. The plain-C paths that have no lua_State to consult --
 * the disk read-gate io.open hits, see fopen_allowed -- read
 * cpu_self()->current, and this runs inside run_proc, where dispatch_lap
 * published that for the whole resume before calling it. So there is
 * nothing to set here: this used to set and clear it around the loop,
 * back when it was a bare global, and clearing it mid-resume is exactly
 * what make_ready must not see -- it would enqueue a proc dispatch_lap
 * still holds.
 *
 * Errors in a handler are swallowed the way a finalizer's are, since
 * there is no longer a caller to report them to.
 */
static void
run_atexit(struct kproc *p)
{
	lua_State *L = p->L;
	int n;

	if (lua_rawgetp(L, LUA_REGISTRYINDEX, &atexit_key) != LUA_TTABLE) {
		lua_pop(L, 1);
		return;
	}
	lua_pushnil(L);
	lua_rawsetp(L, LUA_REGISTRYINDEX, &atexit_key);	/* run once */

	n = (int)luaL_len(L, -1);
	for (int i = n; i >= 1; i--) {
		lua_rawgeti(L, -1, i);
		if (lua_pcall(L, 0, 0, 0) != LUA_OK)
			lua_pop(L, 1);	/* swallow the error message */
	}
	lua_pop(L, 1);		/* the handler table */
}

static int
run_proc(struct kproc *p)
{
	int ran = 0;

	/* WRR: a proc with weight>1 (see sys.set_priority) gets resumed up
	 * to that many times in a row before we move on, instead of exactly
	 * once -- the entire "programmable scheduler" surface is this one
	 * loop bound reading a plain int; no lua code runs inside the
	 * decision.
	 */
	for (int w = 0; w < p->weight; w++) {
		/* collect the waits left behind by whoever woke this proc,
		 * before any lua runs. The loop only comes round again
		 * while p is READY, and a READY proc holding waits is
		 * exactly the woken case, so this is the right place for
		 * it on both the first pass and the rest.
		 *
		 * It has to be before the resume rather than after,
		 * because the double-block test reads the same list: a
		 * proc that called sys.block with stale entries still
		 * attached would be told it was already blocked.
		 */
		wait_reap(p);

		ran = 1;
		cpu_self()->ndispatch++;
		/* where it ran, recorded rather than decided -- nothing
		 * placed it here, this cpu simply took it. Written
		 * outside schedlock because only the cpu running p
		 * writes it, and a reader racing it gets the previous
		 * cpu, which was equally true a moment ago.
		 */
		p->home = cpu_self()->idx;
		p->nresume++;

		int nres = 0;

		unsigned long long t0 = platform_ticks();

		p->resumed = t0;

		/* after p->resumed, so the marker's own cpu delta is
		 * measured against this slice rather than the last one.
		 */
		if (p->trace)
			trace_mark(p, "<scheduled>");

		int rc = lua_resume(p->co, 0, p->nargs, &nres);

		p->nargs = 0;	/* first resume only; see struct kproc */

		p->cputime += platform_ticks() - t0;
		p->resumed = 0;

		/* a proc can run a full hook window (200k insns) before
		 * yielding; drain the 16-byte fifo now so it can't overflow
		 * between serial pumps.
		 */
		/* drain the 16-byte rx fifo, but on a deadline rather than
		 * after every resume.
		 *
		 * the hazard is real: a proc can run a full hook window
		 * before yielding, and a lap can carry LAPSPILL dispatches
		 * before it reaches the top of the loop again, so pump_serial
		 * is not a tight bound on how long the fifo goes undrained.
		 * that is why this is here and not only up there.
		 *
		 * but the drain costs an inb on COM2's LSR, which is a port
		 * i/o trap, and doing it per resume made it 74% of a
		 * cross-proc round trip -- measured, not guessed. at 115200
		 * baud the fifo takes ~1.39ms to fill 16 bytes, so draining
		 * on a deadline a good margin inside that keeps the same
		 * guarantee for two rdtsc and a compare.
		 */
		unsigned long long now = platform_ticks();

		if (now - last_uart_drain >= uart_drain_cycles) {
			uart_poll();
			last_uart_drain = platform_ticks();
		}
		if (rc == LUA_YIELD) {
			lua_pop(p->co, nres);
			if (p->status != READY)
				break;	/* now BLOCKED */
			continue;	/* spend more weight */
		}
		if (rc == LUA_OK) {
			run_atexit(p);
			proc_kill(p, 0);
		}
		else if (rc == LUA_ERRMEM)
			/* lua reports OOM via a static, preallocated message
			 * specifically so it never has to allocate to report
			 * a failure caused by having no memory left.
			 * luaL_traceback would break that guarantee (it
			 * allocates to build the traceback string) and, this
			 * proc being already at its limit, fail again -- skip
			 * it here, same plain message as before.
			 *
			 * it breaks rather than dies all the same: an
			 * out-of-memory corpse is both the one most worth
			 * looking at and the one no traceback can describe,
			 * and sys.stack reads it precisely because
			 * src/debug.c allocates nothing in the target.
			 */
			proc_break(p, lua_tostring(p->co, -1));
		else {
			/* a coroutine that errors out of lua_resume
			 * deliberately does NOT unwind its stack -- that's
			 * what lets luaL_traceback walk it right here, same
			 * trick xpcall's message handler relies on, just done
			 * from the C side after resume already returned
			 * instead of during unwinding.
			 *
			 * error object is on the stack; read it before the
			 * traceback replaces the top.
			 *
			 * the traceback is built here as well as held in
			 * the corpse, because it is what reaches the console
			 * log: the corpse answers a question someone thought
			 * to ask, the log answers the one nobody was there
			 * for.
			 */
			const char *errmsg = lua_tostring(p->co, -1);

			luaL_traceback(p->co, p->co, errmsg, 0);
			proc_break(p, lua_tostring(p->co, -1));
		}
		break;	/* proc died, nothing left to resume */
	}
	return ran;
}

/* two-level poll backoff for com2 (no EFI event backs raw uart rx, see
 * docs/uefi-notes.md): a faster period while bytes are actively
 * arriving, a slower one after a run of empty polls, snapping back the
 * instant a byte shows up. bounds the worst-case "first byte after
 * idle" latency to one slow period while cutting wakeups the rest of
 * the time.
 *
 * these numbers are measured, not requested. SetTimer has a hard floor
 * at the platform's timer-interrupt period -- 10ms under OVMF (100Hz)
 * -- so anything below that is silently rounded up to it, while
 * anything above is honoured accurately (15ms measured 14.975ms). this
 * code used to ask for 1ms and comment "~1ms latency"; it was getting
 * 9.98ms and had been all along. ask for what we can actually have.
 *
 * consequence worth knowing: the fast/slow split is a 1.5x reduction in
 * wakeups (10ms -> 15ms), not the 15x the old constants implied. going
 * slower is possible and cheap, but the slow period IS the
 * first-byte-after-idle latency for interactive 9p over com2, so it is
 * a latency/wakeup trade rather than free.
 */
#define TICK_FAST_100NS  100000		/* 10ms: the OVMF floor, measured */
#define TICK_SLOW_100NS  150000		/* 15ms, honoured accurately */
#define TICK_IDLE_THRESHOLD 25		/* consecutive empty polls before backing off */

/* one lap of dispatch on one cpu: both phases over its own queues,
 * then the drain and the swap. Every cpu that schedules runs this and
 * nothing else -- what the boot processor does around it (the device
 * pumps, the timers, the firmware tick) is machine-wide work that an
 * AP must not touch, not part of scheduling.
 *
 * Returns whether anything ran, which is what the caller's idle
 * decision is made on.
 */
static int
dispatch_lap(struct cpu *me)
{
	int ran = 0;

	lock(&schedlock);
	int budget = runq->n;

	unlock(&schedlock);

	for (int i = 0; i < budget; i++) {
		struct kproc *p;

		lock(&schedlock);
		p = rq_take_high(runq);
		/* a proc somebody is reading is put aside rather than run:
		 * see proc_freeze. Taken and set aside under the one lock,
		 * so it cannot be resumed between the two.
		 */
		if (p && p->frozen) {
			rq_add(donq, p);
			unlock(&schedlock);
			continue;
		}
		/* published under the lock and for the whole resume, so
		 * that make_ready can see this proc is in hand and leave
		 * the requeue below to do the enqueueing.
		 */
		if (p) {
			if (p->oncpu)
				platform_abort("proc dispatched on two cpus");
			p->oncpu = me->idx + 1;
		}
		me->current = p;
		unlock(&schedlock);
		if (!p)
			break;		/* another cpu got there first */
		/* outside the lock, and this is the rule the whole
		 * scheme rests on: a resume runs lua, which can send,
		 * which takes the ipc lock and then this one. Holding
		 * this across it would invert that order and deadlock
		 * against any other cpu doing the same.
		 */
		if (run_proc(p))
			ran = 1;
		/* clearing current and deciding to requeue are one step:
		 * split them and a wakeup landing in between is either
		 * lost or enqueued twice.
		 */
		lock(&schedlock);
		me->current = 0;
		p->oncpu = 0;
		if (p->status == READY && !p->onq)
			rq_add(donq, p);
		unlock(&schedlock);
	}

	/* phase two is bounded for the same reason phase one is, and
	 * it is the bound that makes the lap terminate at all. a proc
	 * woken mid-lap joins the current runq (see make_ready), so
	 * two procs feeding each other messages hand phase two a fresh
	 * proc every time it takes one. an unbounded drain never
	 * reaches the top of the loop again, and expire_timers,
	 * pump_eth and pump_serial all live there -- one busy pair
	 * stops every timer on the machine, in every proc, whether or
	 * not it has anything to do with the pair.
	 *
	 * the floor is what keeps the bound from being expensive: see
	 * LAPSPILL.
	 */
	lock(&schedlock);
	int spill = runq->n < LAPSPILL ? LAPSPILL : runq->n;

	unlock(&schedlock);

	for (int i = 0; i < spill; i++) {
		struct kproc *p;

		lock(&schedlock);
		p = rq_take_any(runq);
		if (p && p->frozen) {	/* as phase one; see there */
			rq_add(donq, p);
			unlock(&schedlock);
			continue;
		}
		if (p) {
			if (p->oncpu)
				platform_abort("proc dispatched on two cpus");
			p->oncpu = me->idx + 1;
		}
		me->current = p;
		unlock(&schedlock);
		if (!p)
			break;
		if (run_proc(p))
			ran = 1;
		lock(&schedlock);
		me->current = 0;
		p->oncpu = 0;
		if (p->status == READY && !p->onq)
			rq_add(donq, p);
		unlock(&schedlock);
	}

	/* the lap ends when runq is empty, and whichever cpu empties it
	 * says so. With one queue that is the only workable boundary: a
	 * cpu cannot swap on its own schedule without handing the others
	 * procs that already had a turn.
	 *
	 * A first version counted the cpus inside a lap and let the last
	 * one out swap. It livelocked, and the measurement is why it was
	 * caught: laps went from 60 at -smp 1 to ~200000 each at -smp 4.
	 * Cpus finishing early re-enter immediately, so "all of them are
	 * out at once" almost never held, the swap kept being deferred,
	 * and every cpu churned empty laps over a runq whose contents
	 * were all sitting in donq.
	 *
	 * What still has to be true is that donq drains: a proc there
	 * runs again only after a swap. runq shrinks on every take, and
	 * the only thing that refills it is a mid-lap wakeup -- so two
	 * procs feeding each other can hold the lap open, which is the
	 * same case phase two's bound exists for, and the bound is what
	 * returns this cpu to kernel_run either way.
	 */
	lock(&schedlock);
	if (runq->n == 0 && donq->n > 0) {
		struct rqset *t = runq;

		runq = donq;
		donq = t;
	}
	unlock(&schedlock);

	return ran;
}

/* what an application processor runs, and the whole of it.
 *
 * The boot processor's loop is the same two phases wrapped in
 * machine-wide work: the device pumps, expire_timers, the firmware
 * tick, the boot payload. None of that is an AP's business. On
 * -Dplatform=efi it could not be even if it were wanted -- TPL is one
 * big cooperative lock (docs/uefi-notes.md) and an AP calling firmware
 * is undefined -- and this platform inherits that division rather than
 * inventing one.
 *
 * The idle is a real sleep, ended by the reschedule ipi that make_ready
 * sends when it puts work on this cpu's queue. It is not a new "wait
 * for the next thing" primitive: it is the same shape efi_shim.c's
 * wait already has, given the one wakeup source an AP has.
 */
void
kernel_run_ap(void)
{
	struct cpu *me = cpu_self();

	lock(&schedlock);
	me->dispatching = 1;
	unlock(&schedlock);

	while (nlive > 0) {
		me->nlaps++;
		if (ipcheld())	/* see kernel_run; the same check */
			platform_abort("ipclock held across a lap");
		if (dispatch_lap(me)) {
			me->ndispatch++;
			continue;
		}

		/* nothing to run. Publish that under the lock, because
		 * make_ready reads it under the same lock to decide
		 * whether to send the ipi -- that is what makes it
		 * impossible to sleep just after someone decided we did
		 * not need waking.
		 *
		 * The lock settles who decides; it does not close the
		 * window. This cpu dispatches with interrupts on, so an
		 * ipi sent the instant after the lock is dropped would be
		 * taken here as an ordinary interrupt, handled, and lost
		 * -- and the sleep below would then never end, with work
		 * already sitting on this queue. So interrupts go off
		 * before the queue is looked at and stay off into
		 * platform_cpu_idle(), which re-enables them as it goes
		 * to sleep.
		 */
		platform_intr_off();
		lock(&schedlock);
		if (runq->n + donq->n > 0) {
			unlock(&schedlock);
			platform_intr_on();
			continue;
		}
		me->idle = 1;
		unlock(&schedlock);

		me->nidle++;
		platform_cpu_idle();	/* returns with interrupts on */

		lock(&schedlock);
		me->idle = 0;
		unlock(&schedlock);
	}

	lock(&schedlock);
	me->dispatching = 0;
	unlock(&schedlock);
}

void
kernel_run(void)
{
	EFI_EVENT tick = 0;
	EFI_EVENT ethwait = platform_dev_wait();
	EFI_EVENT waits[3];
	UINTN index;
	int idle_polls = 0;
	int tick_slow = 0;

	/* periodic timer: idle becomes a real firmware sleep (hlt)
	 * instead of a hot stall-poll. the old "timer hangs the serial
	 * path" mystery was firmware console contention on com2, fixed
	 * by uart_takeover().
	 */
	if (BS->CreateEvent(EVT_TIMER, TPL_CALLBACK, 0, 0, &tick) !=
	    EFI_SUCCESS ||
	    BS->SetTimer(tick, TimerPeriodic, TICK_FAST_100NS) != EFI_SUCCESS)
		tick = 0;

	lock(&schedlock);
	cpu_self()->dispatching = 1;
	unlock(&schedlock);

	while (nlive > 0) {
		struct cpu *me = cpu_self();
		int ran;

		cpu_self()->nlaps++;

		/* nothing may hold the ipc lock across the top of a lap:
		 * every acquisition is inside one call and releases
		 * before returning to here. This catches the release
		 * that a lua error longjmped past, which is the failure
		 * mode the lua-facing acquisitions have and which no
		 * amount of reading finds reliably.
		 *
		 * It asks whether this cpu holds it, not whether anyone
		 * does. Another cpu holding it here is the ordinary case,
		 * and asking lock.h's holding() reported that as a leak
		 * -- a panic that arrives at random on a machine that is
		 * working correctly.
		 */
		if (ipcheld())
			platform_abort("ipclock held across a lap");

		/* drain the periodic timer's signal. nothing is paced
		 * against it any more, but a tick that fires during a busy
		 * lap stays signaled otherwise, and the WaitForEvent below
		 * would then return at once instead of sleeping.
		 */
		if (tick)
			BS->CheckEvent(tick);

		expire_timers();
		pump_eth();
		pump_keyboard();
		pump_devkbd();
		if (pump_serial()) {
			idle_polls = 0;
			if (tick_slow && tick) {
				BS->SetTimer(tick, TimerPeriodic,
				    TICK_FAST_100NS);
				tick_slow = 0;
			}
		} else if (!tick_slow && tick) {
			if (++idle_polls >= TICK_IDLE_THRESHOLD) {
				BS->SetTimer(tick, TimerPeriodic,
				    TICK_SLOW_100NS);
				tick_slow = 1;
			}
		}
		/* dispatch in two phases, and the split is the whole design.
		 *
		 * phase 1 orders by priority: highest first, so an
		 * interactive proc answers before a hog gets another turn.
		 * phase 2 is a plain slot scan that ignores priority
		 * entirely and picks up whatever phase 1 did not run --
		 * including procs woken DURING phase 1.
		 *
		 * phase 2 is the starvation guarantee, and it is deliberately
		 * independent of the priority function. every proc READY when
		 * the lap began runs exactly once in it, whatever
		 * reprioritize() computes, and one woken during the lap runs
		 * in it or in the next. a policy that is buggy, hostile or
		 * merely untuned can cost latency; it cannot wedge the
		 * machine. that matters because policy is exactly the part we
		 * expect to get wrong -- see AGENTS.md.
		 *
		 * plan 9 cannot do this: runproc() scans runq[] from the top
		 * and takes the first thing it finds, with no aging, so a
		 * high-basepri proc starves a low one indefinitely (which
		 * PriEdf > PriKproc > PriNormal makes deliberate). it has
		 * unbounded procs, so an exhaustive sweep would be O(nproc)
		 * per decision. we pay nothing for the guarantee because a
		 * lap is bounded by what was runnable when it started, not
		 * by how many procs exist -- see the budget below.
		 */
		/* phase one takes the highest priority first, so an
		 * interactive proc answers before a hog gets another turn.
		 * it is bounded by how many were waiting when the lap
		 * started, so it cannot spin on procs it keeps waking.
		 *
		 * phase two then takes whatever is left, priority not
		 * consulted -- including anything woken during phase one --
		 * and is bounded too, by how many were waiting when it
		 * started or by LAPSPILL, whichever is larger.
		 *
		 * "already had its turn" is membership in donq rather than a
		 * per-lap marker, so nothing here is sized against MAXPROCS
		 * and nothing scans.
		 */
		ran = dispatch_lap(me);

		if (!ran) {
			/* everyone blocked: sleep until a key, a frame, or
			 * the tick. without the wire in here a frame waits
			 * for the next tick to be noticed, because pump_eth
			 * only runs at the top of a lap and nothing else
			 * ends the sleep.
			 *
			 * ethwait may be 0 -- no card, or a driver that
			 * publishes no event -- and then the tick is the
			 * bound again, which is the behaviour this replaces
			 * rather than a failure.
			 */
			cpu_self()->nidle++;
			if (tick) {
				UINTN n = 0;

				waits[n++] = ST->ConIn->WaitForKey;
				waits[n++] = tick;
				if (ethwait)
					waits[n++] = ethwait;
				BS->WaitForEvent(n, waits, &index);
			} else
				BS->Stall(500);
		}
	}
}

/* disk gates write/append only (read is ambient, see stdio.c's
 * fopen): does whoever is currently resumed hold any right to
 * diskport? used from fopen, which has no lua_State at all --
 * liolib.c's io.open calls it as plain C, so cpu_self()->current is
 * the only way to learn who's asking.
 */
static int
proc_has_port(struct kproc *p, struct kport *port)
{
	if (!p || !port)
		return 0;
	for (int i = 0; i < MAXRIGHTS; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used && r->port == port)
			return 1;
	}
	return 0;
}

int
kernel_current_has_disk(void)
{
	return proc_has_port(cpu_self()->current, diskport);
}
