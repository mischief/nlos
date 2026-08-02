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

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "efi.h"
#include <sys/queue.h>

#include "kernel.h"
#include "net.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luaheap.h"
#include "debug.h"
#include "platform.h"

/* bodies are heap-allocated, so what these cost statically is one pointer
 * each: 4096 procs and 32768 ports is 288KB of .bss, and a machine
 * running a dozen procs allocates a dozen bodies.
 *
 * these are headroom rather than reachable counts. spawning until it
 * fails stops at about 960 procs, because each is a lua_State and the
 * heap runs out long before the tables do. dispatch and wakeups do not
 * scan, so the round trip is flat across the whole range (about 26k
 * cycles at 64 procs and at 8192).
 *
 * going further wants a two-level index rather than a flat one, which
 * would add an indirection to every serialize.
 *
 * MAXRIGHTS is what bounds a supervisor: sys.spawn hands the parent a
 * right per child, so holding them caps the tree at MAXRIGHTS unless the
 * parent closes each handle and tracks children by pid through
 * sys.monitor. only the first NRIGHTS_INLINE cost anything per proc.
 */
#define MAXPROCS	4096
#define MAXPORTS	32768
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
#define MAXGRANTS	8	/* named capabilities the kernel hands a proc */
#define MAXTIMERS	32	/* outstanding one-shot timers, machine-wide */
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
    PRIV_TCP, PRIV_UDP, PRIV_P9, PRIV_ETH, PRIV_FB };

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
#define TRACESRC	32	/* distinct source files remembered */
#define TRACECO		16	/* coroutines distinguished, as in debug.c */
#define TRACEMAX	4096	/* entries, per proc */

struct tracent {
	int line;
	unsigned short src;	/* index into ktrace.name */
	unsigned short co;	/* index into ktrace.co */
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
	int nrights;	/* rights + in-flight message refs + kernel refs */
	int nrecv;	/* receive rights among those */
	int dead;	/* no receive right left; sends are dropped */
	size_t qbytes;	/* queued payload, against MAXQUEUE */
	struct kmsg *head, *tail;
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

/* dispatch keeps two of these and swaps them each lap: one holds procs
 * still to run, the other those that have run. membership is what says
 * "already had its turn", so there is no per-lap array to size against
 * MAXPROCS and nothing to scan.
 *
 * buckets by priority with a mask of the non-empty ones, so taking the
 * highest is a bit scan rather than a search -- plan 9's runq[].
 */
#define NRQ 16

struct rqset {
	TAILQ_HEAD(rqbucket, kproc) q[NRQ];
	unsigned mask;
	int n;
};

struct waiter {
	struct kproc *p;
	struct kport *port;
	int send;			/* waiting for room, not for a message */
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
	int watchers[MAXWATCH];	/* pids to notify when this proc dies */
	int nwatch;
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
	struct grant grants[MAXGRANTS];
	int ngrants;
	struct ktrace *trace;	/* line trace ring, or 0; see sys.set_trace */
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
static struct kport *portv[MAXPORTS];
static int porthigh;		/* one past the highest slot ever used */
static struct kport *kbdport;
static int nlive;

/* one heap behind every lua_State on the machine.
 *
 * A heap per proc is the obvious arrangement and is worse, measured: a
 * proc's lua heap is only ~39K, so the tail of its last chunk and the
 * page rounding underneath it get paid once per proc instead of once
 * for the machine. Per proc that was 57514 bytes against 52053 shared,
 * and the waste inside the heap was 20% against 6%.
 *
 * What a per-proc heap would have bought does not survive looking at:
 * teardown cannot skip lua_close anyway, since __gc finalizers are how
 * handles get clunked; there is nothing to lock either way under
 * cooperative scheduling; and one proc reusing another's freed blocks
 * lowers total fragmentation rather than raising it. Containment is
 * unaffected -- mem_used and mem_limit are counted in kalloc, per proc,
 * and never depended on the heap being separate.
 *
 * The one thing given up is that a proc which allocates hugely and dies
 * no longer hands those pages back to the firmware; they stay in the
 * free lists. Returning wholly-empty chunks would fix that and is not
 * built.
 */
static struct luaheap *proc_heap;
static int nextpid;

/* who's running right now. kernel_run sets this before every
 * lua_resume and clears it after. plain C code with no lua_State
 * (stdio.c's fopen, called via liolib.c with no proc identity
 * threaded through) uses this to find out who's asking -- the only
 * way to check a capability from a context where self(L) isn't
 * available at all.
 */
static struct kproc *current_proc;


/* how many times kernel_run has found every proc blocked and gone to
 * a real firmware sleep. exposed via sys.stats() as an idleness
 * signal: a machine that is genuinely idle advances this steadily,
 * one that is busy-spinning (some proc always READY) never does. that
 * distinction is otherwise invisible from inside a proc -- wchan
 * sampling can't see it, because a task woken and re-blocked between
 * two samples looks identical to one that never woke.
 */
static unsigned long long nidle;

/* dispatch accounting, for answering "where does a round trip go?"
 * without guessing -- laps per round trip is what showed the ping-pong
 * never reaches the top of a lap, and so that pump_serial is no bound on
 * how long the uart fifo goes undrained. plain increments; anything
 * needing a timestamp belongs in a temporary probe, not here.
 */
static unsigned long long nlaps, ndispatch;

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
static void rq_init(void);
static void rq_del(struct kproc *p);
static void rq_add(struct rqset *set, struct kproc *p);
static struct kproc *rq_take_high(struct rqset *set);
static struct kproc *rq_take_any(struct rqset *set);
static void make_ready(struct kproc *p);

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

/* net's own wakeup: a kernel-owned port, exactly like kbdport/serport,
 * except fed by pump_net's ping rather than by bytes showing up --
 * net.c's completions are token/Event based (see kernel_new_net_event
 * below for why nothing but net.c's own poll may touch those events).
 * whoever holds netport's recv right (the net task) just does an
 * ordinary thread.recv -- same proven wakeup path as every other
 * blocking primitive here, no new primitive with its own race to get
 * wrong.
 */
static struct kport *netport;
static struct kport *udpport;

/* true once net_init() has located tcp4 and the net task has been (or
 * will be) spawned; guards pump_net so it doesn't push into netport
 * forever with no reader when there's no NIC -- netport would never
 * gain a receive right in that case, so nothing would ever mark it
 * dead, and the queue would grow unbounded.
 */
static int have_net;
static int have_udp;
static int have_p9;
static int have_eth;
static int have_fb;

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
 * earns that at thousands of timers; MAXPROCS is 32, so there are a few
 * dozen at most and both things we do each lap (expire the due ones,
 * and nothing else) are one pass over a tiny array. sorting would buy
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
	for (int i = 0; i < MAXTIMERS; i++)
		if (timers[i].port && timers[i].port->dead) {
			port_unref(timers[i].port);
			timers[i].port = 0;
		}
}

static void
expire_timers(void)
{
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
}

/* net.c calls this instead of BS->CreateEvent directly. */
EFI_EVENT
kernel_new_net_event(void)
{
	EFI_EVENT ev;

	/* plain event, NO notify function and NOT registered in
	 * kernel_run's own wait array. proven via test/tcp4echo (a
	 * standalone app with no lua-os kernel at all) that a bare
	 * CheckEvent-polled event works correctly end to end; a
	 * notify-signal event does not, here, on this firmware -- the
	 * notify dispatch itself appears to consume the signaled state
	 * as a side effect of merely running, so by the time net.c's own
	 * CheckEvent poll runs afterward the signal is already gone even
	 * though the operation genuinely completed. same reasoning rules
	 * out registering it in kernel_run's wait array too: kernel_run's
	 * own WaitForEvent call would consume it there instead, before
	 * net.c's poll ever gets a look. pump_net's netport ping (which
	 * never touches this event's state at all) is the only wakeup
	 * source now; net.c's own poll functions are the sole code that
	 * ever calls CheckEvent on a tcp4 token.
	 */
	if (BS->CreateEvent(0, 0, 0, 0, &ev) != EFI_SUCCESS)
		return 0;
	return ev;
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
	struct kport *port = r->port;

	r->used = 0;
	if (r->recv)
		port->nrecv--;
	port_unref(port);
}

/* grant a named capability: take a right the ordinary way (first free
 * slot) and record what it was called, so lua can look the handle up
 * by name. a NULL port or a full table is a no-op, which is exactly
 * the "this capability doesn't exist this boot" case.
 */
static void
grant_named(struct kproc *p, const char *name, struct kport *port, int recv)
{
	if (!port || p->ngrants >= MAXGRANTS)
		return;

	int h = right_new(p, port, recv);

	if (h < 0)
		return;
	p->grants[p->ngrants].name = name;
	p->grants[p->ngrants].handle = h;
	p->ngrants++;
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
		/* {__right = handle} transfers a right. if __right is present
		 * but not an integer handle it's a mistake (e.g. a float);
		 * refuse it rather than silently shipping the table as data
		 * and dropping the intended capability.
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
			if (deserialize(L, p, len, off, receiver, depth + 1) ||
			    deserialize(L, p, len, off, receiver, depth + 1))
				return -1;
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

		if (h < 0)
			return -1;
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
	TAILQ_INSERT_TAIL(&port->waiters, w, pq);
	SLIST_INSERT_HEAD(&p->waiters, w, pw);
	return 1;
}

/* drop every wait this proc holds. called on wake and on death, so it has
 * to be safe to call when the list is already empty.
 */
static void
wait_clear(struct kproc *p)
{
	while (!SLIST_EMPTY(&p->waiters)) {
		struct waiter *w = SLIST_FIRST(&p->waiters);

		SLIST_REMOVE_HEAD(&p->waiters, pw);
		TAILQ_REMOVE(&w->port->waiters, w, pq);
		if (w == &p->w0)
			p->w0used = 0;
		else
			free(w);
	}
}

static void
wake_receivers(struct kport *port)
{
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (w->send || p->status != BLOCKED)
			continue;
		/* clears every wait p holds, including the one we are
		 * standing on, which is why the SAFE form is required
		 */
		wait_clear(p);
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
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (!w->send || p->status != BLOCKED)
			continue;
		wait_clear(p);
		make_ready(p);
	}
}

/* queue a message. refs/nrefs are in-flight right refs (may be null).
 * a dead port silently drops -- erlang semantics, the sender learns
 * from the monitor, not the send.
 */
/* takes ownership of `data` unconditionally: on success the queued
 * message owns it, and on every failure path (including a dead port)
 * this frees it. callers must not free or reuse it afterwards.
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
	if (port->dead) {
		release_inflight(refs, refrecv, nrefs);
		free(data);
		return 0;
	}

	if (port->qbytes + len > MAXQUEUE) {
		release_inflight(refs, refrecv, nrefs);
		free(data);
		return -2;		/* full, distinct from out of memory */
	}

	struct kmsg *m = malloc(sizeof *m);

	if (!m) {
		free(data);
		return -1;
	}
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
	unsigned char *copy = malloc(len);

	if (!copy) {
		release_inflight(refs, 0, nrefs);
		return -1;
	}
	memcpy(copy, data, len);
	return port_push_owned(port, copy, len, refs, 0, nrefs);
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
	return current_proc && current_proc->priv == PRIV_BOOT;
}

/* ---- lua api (proc pointer lives in the state's extra space) ---- */

static struct kproc *
self(lua_State *L)
{
	return *(struct kproc **)lua_getextraspace(L);
}

/* serialize the value at `idx` and queue it on r's port. shared by
 * api_send and api_call, which differ only in what they do afterwards.
 * the wbuf is disposed of on every path, success or not.
 */
enum { SEND_OK = 0, SEND_UNSERIALIZABLE, SEND_DEAD, SEND_FULL, SEND_NOMEM };

static int
port_send_from_lua(lua_State *L, struct kproc *p, struct right *r, int idx)
{
	struct wbuf w = { 0 };

	wreserve(&w, sizehint(L, idx));
	if (serialize(L, idx, &w, p, 0)) {
		/* release refs taken for rights serialized before the
		 * failure point
		 */
		release_inflight(w.refs, w.refrecv, w.nrefs);
		free(w.p);
		return SEND_UNSERIALIZABLE;
	}
	if (r->port->dead) {
		release_inflight(w.refs, w.refrecv, w.nrefs);
		free(w.p);
		return SEND_DEAD;
	}
	int rc = port_push_owned(r->port, w.p, w.len, w.refs, w.refrecv,
	    w.nrefs);

	if (rc == -2)		/* w.p already freed by port_push_owned */
		return SEND_FULL;
	if (rc)
		return SEND_NOMEM;
	return SEND_OK;
}

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r)
		return luaL_error(L, "bad right");
	luaL_checkany(L, 2);

	int rc = port_send_from_lua(L, p, r, 2);

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

/* a proc about to block must hold no waits, because a proc that is
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
static int
blocking_twice(lua_State *L, struct kproc *p)
{
	if (SLIST_EMPTY(&p->waiters))
		return 0;
	return luaL_error(L, "already blocked (sys.block from a coroutine? "
	    "use los.thread's park)");
}

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
static int
api_sendblock(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));
	lua_Integer need = luaL_optinteger(L, 2, 0);

	if (!r)
		return luaL_error(L, "bad right");
	if (need < 0)
		return luaL_error(L, "negative size");
	blocking_twice(L, p);
	if (r->port->dead)
		return 0;	/* never going to drain; let the send report it */
	if ((size_t)need > MAXQUEUE)
		return 0;	/* can never fit; let the send report it */
	if (r->port->qbytes + (size_t)need <= MAXQUEUE)
		return 0;	/* room already, don't sleep */
	if (!wait_add(p, r->port, 1))
		return luaL_error(L, "out of waiters");
	p->status = BLOCKED;
	rq_del(p);
	return lua_yield(L, 0);
}

/* take the head message off `port` and push it as ONE lua value. the
 * caller must have established that port->head is non-null; "nothing
 * there" is the one thing this cannot express, and it is exactly what
 * the two callers disagree about (tryrecv reports it, api_call sleeps
 * on it), which is why the emptiness test stays outside.
 *
 * returns -1 on a corrupt message, having pushed nothing.
 */
static int
port_pop_to_lua(lua_State *L, struct kproc *p, struct kport *port)
{
	struct kmsg *m = port->head;

	port->head = m->next;
	if (!port->head)
		port->tail = 0;
	port->qbytes -= m->len;
	/* room freed: this is the ordinary backpressure wakeup */
	wake_senders(port);

	size_t off = 0;

	if (deserialize(L, m->data, m->len, &off, p, 0)) {
		msg_free(m);
		return -1;
	}
	/* receiver now holds its own refs (right_new); drop in-flight */
	msg_free(m);
	return 0;
}

static int
api_tryrecv(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (!r->port->head) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	if (port_pop_to_lua(L, p, r->port))
		return luaL_error(L, "corrupt message");
	return 2;
}

static int
api_block(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (r->port->head)
		return 0;	/* message already there, don't sleep */
	blocking_twice(L, p);
	if (!wait_add(p, r->port, 0))
		return luaL_error(L, "out of waiters");
	p->status = BLOCKED;
	rq_del(p);
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
	struct right *rr = right_get(p, (int)ctx);

	(void)status;
	/* re-resolved rather than carried across the yield: a handle is an
	 * index into a table this proc can rearrange, and the struct right
	 * behind it may have moved. the proc cannot have closed it while
	 * parked here, so failing to find it is a bug rather than a race.
	 */
	if (!rr || !rr->recv)
		return luaL_error(L, "call: reply right went away");
	if (!rr->port->head) {
		/* nobody left who could answer: our right is the last one, so
		 * the one that rode out with the request is gone. checked
		 * before parking again, since the wake that brought us here is
		 * usually the very drop being tested for (port_unref wakes
		 * receivers), and after the queue test so a reply that did
		 * arrive is delivered even when the server answered and died.
		 */
		if (rr->port->nrights <= 1) {
			lua_pushnil(L);
			lua_pushliteral(L, "hungup");
			return 2;
		}
		/* woken with nothing for us -- another thread in this proc
		 * took the message first. park again. wake_receivers already
		 * dropped our waiter, so this adds a fresh one rather than
		 * leaking the old.
		 */
		if (!wait_add(p, rr->port, 0))
			return luaL_error(L, "out of waiters");
		p->status = BLOCKED;
		rq_del(p);
		return lua_yieldk(L, 0, ctx, call_k);
	}
	if (port_pop_to_lua(L, p, rr->port))
		return luaL_error(L, "corrupt message");
	return 1;
}

static int
api_call(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));
	lua_Integer rh = luaL_checkinteger(L, 3);
	struct right *rr = right_get(p, rh);

	if (!r)
		return luaL_error(L, "call: bad right");
	if (!rr || !rr->recv)
		return luaL_error(L, "call: bad reply right");
	luaL_checkany(L, 2);
	/* before the send, not after: refusing a call we cannot finish is
	 * better than delivering a request whose answer nobody will collect.
	 *
	 * checked even though call_k takes an already-queued reply without
	 * yielding at all -- a call that happens to work from a coroutine
	 * when the server is same-proc and corrupts the waiter list when it
	 * is not is worse than one that always refuses. los.thread's call()
	 * is the shape for a thread, and picks this only at the top level.
	 */
	blocking_twice(L, p);

	int rc = port_send_from_lua(L, p, r, 2);

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
		if (r && r->recv && r->port->head)
			return i;
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
	if (port_pop_to_lua(L, p, r->port))
		return luaL_error(L, "corrupt message");
	return 2;
}

/* sys.altrecvnb(set) -> index, msg | nothing. the non-blocking form, for
 * a proc that is still runnable and only wants what is already there.
 */
static int
api_altrecvnb(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	return altrecv_take(L, self(L));
}

static int
altrecv_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	(void)ctx;
	/* nothing for us after all -- a hangup wake, or another proc took
	 * it. returning nothing is legal and means "go round again".
	 */
	return altrecv_take(L, self(L));
}

/* block until any of a set of receive rights has a message (port set) */
static int
api_altblock(lua_State *L)
{
	struct kproc *p = self(L);
	int n;

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1)
		return luaL_error(L, "altblock: need at least one port");

	wait_clear(p);
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, luaL_checkinteger(L, -1));

		lua_pop(L, 1);
		if (!r || !r->recv) {
			wait_clear(p);
			return luaL_error(L, "altblock: bad receive right");
		}
		if (r->port->head) {
			wait_clear(p);
			lua_pushinteger(L, i);
			return 1;	/* already ready, don't sleep */
		}
		/* dedup: the caller may list the same handle more than once,
		 * since alt cases share ports. two waits on one port would
		 * both fire and both be released by wait_clear, so this is
		 * about not consuming the pool rather than correctness.
		 */
		int seen = 0;
		struct waiter *w;

		SLIST_FOREACH(w, &p->waiters, pw)
			if (w->port == r->port) {
				seen = 1;
				break;
			}
		if (!seen && !wait_add(p, r->port, 0)) {
			wait_clear(p);
			return luaL_error(L, "altblock: out of waiters");
		}
	}
	p->status = BLOCKED;
	rq_del(p);
	return lua_yieldk(L, 0, 0, altblock_k);
}

/* sys.altrecv(set) -> index, msg. blocks, then takes. */
static int
api_altrecv(lua_State *L)
{
	struct kproc *p = self(L);
	int n;

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1)
		return luaL_error(L, "altrecv: need at least one port");

	int got = altrecv_take(L, p);

	if (got)
		return got;

	wait_clear(p);
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, (int)luaL_checkinteger(L, -1));

		lua_pop(L, 1);
		if (!r || !r->recv) {
			wait_clear(p);
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
			return luaL_error(L, "altrecv: out of waiters");
		}
	}
	p->status = BLOCKED;
	rq_del(p);
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
	struct kport *port = port_new();

	if (!port)
		return luaL_error(L, "out of ports");
	int h = right_new(p, port, 1);

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
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r)
		return luaL_error(L, "bad right");

	int h = right_new(p, r->port, 0);

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, h);
	return 1;
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
			if (serialize(L, -1, &argw, p, 0)) {
				release_inflight(argw.refs, argw.refrecv,
				    argw.nrefs);
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
	int pid = proc_new(code, n, chunkname, 0, reductions, mem_limit,
	    PRIV_NONE);

	if (is_dumped)
		free(buf.data);	/* proc_new/luaL_loadbuffer copies, doesn't keep it */

	if (pid < 0) {
		release_inflight(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
		return luaL_error(L, "spawn failed");
	}

	struct kproc *child = find_proc(pid);

	if (!child) {
		release_inflight(argw.refs, argw.refrecv, argw.nrefs);
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

		if (deserialize(child->co, argw.p, argw.len, &off, child, 0)) {
			/* a partial deserialize may have left values on co's
			 * stack under the chunk's feet, and rights already
			 * minted into the child. the proc is unusable; kill
			 * it rather than start it half-built.
			 */
			release_inflight(argw.refs, argw.refrecv, argw.nrefs);
			free(argw.p);
			proc_kill(child, "spawn: could not deliver arg");
			return luaL_error(L, "spawn: could not deliver arg");
		}
		child->nargs = 1;
		/* the in-flight ref taken by serialize; the child now holds
		 * its own from right_new, exactly as a delivered message
		 * releases its refs once received.
		 */
		release_inflight(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
	}
	/* hand parent a send right on the child's self port */
	int h = right_new(p, child->rights[0].port, 0);

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
		notify_exit(p, pid, "noproc", -1, 0, 0);
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
	lua_Integer h = luaL_checkinteger(L, 1);
	struct right *r = right_get(p, h);

	if (!r)
		return luaL_error(L, "bad right");
	if (h == 0)
		return luaL_error(L, "cannot close self port");
	right_drop(r);
	if ((int)h < p->rhint)
		p->rhint = (int)h;	/* reuse the slot we just freed */
	return 0;
}

static void preempt_hook(lua_State *L, lua_Debug *ar);

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
	lua_pushinteger(L, (lua_Integer)nidle);
	lua_setfield(L, -2, "idles");
	lua_pushinteger(L, rights_high);
	lua_setfield(L, -2, "rightshigh");
	lua_pushinteger(L, (lua_Integer)nlaps);
	lua_setfield(L, -2, "laps");
	lua_pushinteger(L, (lua_Integer)ndispatch);
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

	/* the lua heap every proc shares. live is what the states between
	 * them asked for; mapped is what the machine holds to serve it, and
	 * the gap is what bounds how many procs fit.
	 *
	 * Note heap_used above counts these chunks as ordinary C
	 * allocations, since that is what they are -- so the two are not
	 * additive.
	 */
	struct luaheap_stats hs;

	luaheap_stats(proc_heap, &hs);
	lua_pushinteger(L, (lua_Integer)hs.live);
	lua_setfield(L, -2, "lua_live");
	lua_pushinteger(L, (lua_Integer)hs.mapped);
	lua_setfield(L, -2, "lua_mapped");
	lua_pushinteger(L, (lua_Integer)hs.waste);
	lua_setfield(L, -2, "lua_waste");
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
static int
api_wchan(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
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

/* sys.stack(pid) -> { {source=, line=, name=, what=}, ... }
 *
 * a traceback of ANOTHER proc, which is only safe because we are
 * cooperative and single-threaded: every proc except the caller is
 * suspended between lua_resume calls, and lua_getstack/lua_getinfo on a
 * suspended coroutine are ordinary read-only debug API. no stopping the
 * world, no signals, no race.
 *
 * two rules make it safe, and both were learned the hard way elsewhere
 * in this kernel:
 *
 * 1. NOTHING is pushed onto the target's stack. the "Sln" info string is
 *    push-free (unlike "f" or "L"), and every result table is built on
 *    the CALLER's state. leave the target unbalanced and it resumes into
 *    garbage.
 * 2. NO lua code runs in the target. luaL_traceback would allocate in
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

static int
api_stack(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}

	/* src/debug.c: every coroutine, not just the proc's own. A proc
	 * built on lib/thread keeps its threads as coroutines inside its
	 * state, and walking only p->co reported the scheduler -- the same
	 * three frames for an idle proc and a deadlocked one.
	 */
	debug_push_stacks(L, p->L, p->co);
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
static int
api_set_trace(lua_State *L)
{
	struct kproc *p = self(L);
	int arg = 1;
	lua_Integer n;

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

	if (trace_arm(p, (int)n) != 0)
		return luaL_error(L, "out of memory");
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.trace([pid]) -> { {source=, line=, thread=}, ... }, oldest first.
 *
 * readable on a corpse, which is the point: the ring is freed with the
 * state, so a broke proc still says how it got where it stopped.
 */
static int
api_trace(lua_State *L)
{
	struct kproc *p = self(L);
	struct ktrace *t;
	unsigned int n, start;

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
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

		lua_createtable(L, 0, 3);
		lua_pushstring(L, e->src < t->nname ? t->name[e->src] : "?");
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, e->line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, e->co);
		lua_setfield(L, -2, "thread");
		lua_rawseti(L, -2, (int)i + 1);
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

/* sys.granted(): {name = handle} for every capability the kernel
 * handed this proc at spawn. empty for an ordinary sys.spawn child,
 * which is granted nothing; populated for the boot payload. absent key
 * means "this machine doesn't have that" -- see struct grant.
 */
static int
api_granted(lua_State *L)
{
	struct kproc *p = self(L);

	lua_createtable(L, 0, p->ngrants);
	for (int i = 0; i < p->ngrants; i++) {
		lua_pushinteger(L, p->grants[i].handle);
		lua_setfield(L, -2, p->grants[i].name);
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
	if (slot < 0)
		return 0;

	struct kport *port = port_new();

	if (!port)
		return 0;

	int h = right_new(p, port, 1);

	if (h < 0) {
		port->used = 0;
		return 0;
	}
	port->nrights++;	/* the timer table's own ref */
	timers[slot].port = port;
	timers[slot].due_ms = uptime_ms() + (unsigned long long)ms;
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
	{ "granted", api_granted },
	{ "name", api_procname },
	{ "wchan", api_wchan },
	{ "stack", api_stack },
	{ "reap", api_reap },
	{ "set_trace", api_set_trace },
	{ "trace", api_trace },
	{ "set_priority", api_set_priority },
	{ "priority", api_priority },
	{ "ticks", api_ticks },
	{ "uptime_ms", api_uptime_ms },
	{ "timer", api_timer },
	{ "setexit", api_setexit },
	{ "hungup", api_hungup },
	{ NULL, NULL }
};

extern int luaopen_los_efi(lua_State *L);		/* los.c: firmware info */
extern int luaopen_los_fs(lua_State *L);		/* dirs.c: readdir/stat */
extern int luaopen_crypto_chacha20(lua_State *L);	/* crypto.c */
extern int luaopen_crypto_poly1305(lua_State *L);	/* crypto.c */
extern int luaopen_los_platform_cons(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_wire(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_power(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_tcp(lua_State *L);	/* net.c */
extern int luaopen_los_platform_udp(lua_State *L);	/* net.c */
extern int luaopen_los_platform_p9(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_eth(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_fb(lua_State *L);	/* gop.c: efi only, no-op elsewhere */

/* the los.sys module: the microkernel abi (ports, rights, procs) plus
 * kernel-owned primitives that outlive efi (ticks). registered in
 * package.preload by proc_new; a chunk pulls it in with an explicit
 * require("los.sys"). the proc pointer comes from the state's extra
 * space, so the api needs no upvalues.
 */
static int
los_sys_open(lua_State *L)
{
	luaL_newlib(L, kapi);

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
	return malloc(n);
}

static void
kalloc_free_chunk(void *ud, void *p, size_t n)
{
	(void)ud;
	(void)n;
	free(p);
}

static const struct luaheap_ops kalloc_ops = {
	.chunk_alloc = kalloc_chunk,
	.chunk_free = kalloc_free_chunk,
};


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
		luaheap_realloc(proc_heap, ptr, real_osize, 0);
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

	void *q = luaheap_realloc(proc_heap, ptr, real_osize, nsize);

	if (!q)
		return 0;
	p->mem_used += nsize - real_osize;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	return q;
}

/* tear down a proc's state.
 *
 * lua_close frees every block the proc held back into the shared heap's
 * free lists, where the next proc picks them up. It cannot be skipped:
 * __gc finalizers are how handles get clunked, so discarding the memory
 * without running them would leak what the memory was only pointing at.
 */
static void
proc_freestate(struct kproc *p)
{
	if (p->L)
		lua_close(p->L);
	p->L = 0;
	p->co = 0;
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

/* re-arm the whole proc after a mask change.
 *
 * every coroutine, not just p->co, because lua_newthread copies the
 * hook when it is created and never looks again -- so a proc on
 * lib/thread would otherwise have its scheduler traced and none of its
 * threads, which is the reverse of what anyone wants. see
 * debug_sethook_all.
 */
static void
proc_rearm(struct kproc *p)
{
	if (!p->L || !p->co)
		return;
	debug_sethook_all(p->L, p->co, preempt_hook, proc_hookmask(p),
	    p->reductions);
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

	struct tracent *e = &t->ent[t->n % t->cap];

	e->line = ar->currentline;
	e->src = (unsigned short)src;
	e->co = (unsigned short)co;
	t->n++;
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
	/* the forced trip below leaves p->co sampling every instruction.
	 * put it back the moment it has done its job, which is the first
	 * time the hook fires on p->co afterwards.
	 */
	if (p && L == p->co && lua_gethookcount(L) != p->reductions)
		lua_sethook(p->co, preempt_hook, proc_hookmask(p),
		    p->reductions);
	if (!lua_isyieldable(L))
		return;
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
	if (p && L != p->co)
		lua_sethook(p->co, preempt_hook, proc_hookmask(p), 1);
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
	p->L = lua_newstate(kalloc, p);
	if (!p->L)
		return -1;
	/* stash the proc pointer where the kernel api finds it (self()).
	 * set before the thread is created so lua_newthread copies it into
	 * the coroutine's extra space too.
	 */
	*(struct kproc **)lua_getextraspace(p->L) = p;
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

	/* crypto.chacha20 and crypto.poly1305 (src/crypto.c). Ambient,
	 * unlike everything below, and the distinction is the one this
	 * file already draws for sys.send: authority is an ARGUMENT here,
	 * not the function. It computes on a key the caller supplies and
	 * does nothing for a caller that has not got one -- so there is
	 * nothing to attenuate and no owner to be the only one. Contrast
	 * los.platform.rng, where the raw draw IS the capability.
	 *
	 * These take the module names the Lua implementations had, so
	 * nothing that requires them knows the difference. The Lua ones
	 * live on in the host tree (~/code/lua/ssh), where the RFC 8439
	 * vectors run against both and would catch a disagreement; there
	 * is no reason to carry a second copy of the arithmetic here.
	 */
	lua_pushcfunction(p->L, luaopen_crypto_chacha20);
	lua_setfield(p->L, -2, "crypto.chacha20");

	lua_pushcfunction(p->L, luaopen_crypto_poly1305);
	lua_setfield(p->L, -2, "crypto.poly1305");
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
	case PRIV_TCP:
		lua_pushcfunction(p->L, luaopen_los_platform_tcp);
		lua_setfield(p->L, -2, "los.platform.tcp");
		break;
	case PRIV_UDP:
		lua_pushcfunction(p->L, luaopen_los_platform_udp);
		lua_setfield(p->L, -2, "los.platform.udp");
		break;
	case PRIV_P9:
		lua_pushcfunction(p->L, luaopen_los_platform_p9);
		lua_setfield(p->L, -2, "los.platform.p9");
		break;
	case PRIV_ETH:
		lua_pushcfunction(p->L, luaopen_los_platform_eth);
		lua_setfield(p->L, -2, "los.platform.eth");
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
	port_push_owned(watcher->rights[0].port, w.p, w.len, 0, 0, 0);
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
	rq_del(p);
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
	proc_freestate(p);
	proc_detach(p, why, reason, 0);
	p->status = DEAD;
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

	while (n < 256 && (c = uart_rx()) >= 0)
		buf[5 + n++] = (unsigned char)c;
	if (n == 0)
		return 0;
	/* serialized string message: tag, u32 len, bytes */
	buf[0] = 'S';
	memcpy(buf + 1, &n, 4);
	port_push(serport, buf, 5 + n, 0, 0);
	return 1;
}

/* ---- net pump ---- */

/* tcp4 completion events created by kernel_new_net_event() are plain
 * (no notify function, not in kernel_run's wait array) -- the owning
 * task's own CheckEvent poll is the only thing that ever consumes
 * their signaled state. a notify function was tried first and broke:
 * the notify dispatch itself appeared to consume the event's signal
 * as a side effect of running, so a real inbound connection completed
 * fully at the wire level (confirmed via packet capture) yet the
 * later CheckEvent poll always saw "not signaled."
 *
 * pump_net is therefore the sole wakeup: nudge netport so net.lua
 * reruns checkpending() and polls its outstanding tokens directly.
 *
 * the ping is TICK-PACED and coalesced, not issued every lap. issuing
 * it unconditionally (the first version of this) kept the net task
 * permanently READY: kernel_run's `ran` flag was then set on every
 * lap, so the WaitForEvent idle path never executed at all whenever a
 * NIC was present and the machine spun at full tilt instead of
 * sleeping. coalescing alone doesn't fix that -- the task drains the
 * ping the same lap it arrives, so the next lap pushes another one.
 *
 * pacing it to the timer (see kernel_run) is what actually fixes it:
 * one ping per tick period bounds completion latency exactly the way
 * the serial pump's latency is already bounded, and between ticks
 * every proc is blocked, so the machine reaches a real firmware
 * sleep. the queue check on top means a slow task can't accumulate a
 * backlog of pings it will never need.
 */
static void
pump_net(void)
{
	if (have_net && netport && !netport->head)
		port_push(netport, (const unsigned char *)"N", 1, 0, 0);
	if (have_udp && udpport && !udpport->head)
		port_push(udpport, (const unsigned char *)"N", 1, 0, 0);
}

/* ---- keyboard pump ---- */

static void
pump_keyboard(void)
{
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
		if (key.UnicodeChar == 0 || key.UnicodeChar >= 0x80)
			continue;
		msg[5] = (unsigned char)key.UnicodeChar;
		port_push(kbdport, msg, sizeof msg, 0, 0);
	}
}

/* ---- kernel ---- */

int
kernel_init(void)
{
	calibrate_reductions();	/* kernel_clock_init already ran in efi_main */
	rq_init();		/* before any proc exists to be dispatched */
	proc_heap = luaheap_new(&kalloc_ops, 0);
	if (!proc_heap)		/* before any proc exists to allocate */
		return -1;
	uart_init();
	kbdport = port_new();
	serport = port_new();
	diskport = port_new();
	netport = port_new();
	udpport = port_new();
	schedport = port_new();
	if (!kbdport || !serport || !diskport || !netport || !udpport ||
	    !schedport)
		return -1;
	/* kernel refs: the pumps (and, for diskport/netport/schedport,
	 * the kernel itself) hold these ports forever
	 */
	kbdport->nrights++;
	serport->nrights++;
	diskport->nrights++;
	netport->nrights++;
	udpport->nrights++;
	schedport->nrights++;

	/* soft-fail: no NIC (real hardware, or qemu -net none) just means
	 * no net task gets spawned later, same as any other optional
	 * boot-time resource.
	 */
	have_net = (net_init() == 0);
	have_udp = net_have_udp();
	have_p9 = platform_have_p9();
	have_eth = platform_have_eth();
	have_fb = platform_have_fb();
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
		  .what = "the 9p wire", .enabled = 1, .capname = "wire" },
		/* the esp server: the only proc that reaches the disk
		 * directly. it gets diskport at handle 1, so writes are
		 * possible here and nowhere else.
		 */
		{ .path = "/task/espsrv.lua", .chunkname = "=esp",
		  .priv = PRIV_ESP, .devport = diskport, .devrecv = 0,
		  .what = "the esp filesystem", .enabled = 1,
		  .capname = "esp" },
		{ .path = "/task/power.lua", .chunkname = "=power",
		  .priv = PRIV_POWER, .devport = 0, .devrecv = 0,
		  .what = "reset/stall", .enabled = 1, .capname = "power" },
		/* no NIC (real hardware, or qemu -net none) is the normal
		 * case, not a boot failure -- don't even try spawning a task
		 * that could never listen/dial successfully. tcp and udp are
		 * two separate exclusive tasks (see PRIV_TCP/PRIV_UDP),
		 * soft-failing independently of each other.
		 */
		{ .path = "/task/tcp.lua", .chunkname = "=tcp",
		  .priv = PRIV_TCP, .devport = netport, .devrecv = 1,
		  .what = "networking (tcp)", .enabled = have_net,
		  .capname = "tcp" },
		{ .path = "/task/udp.lua", .chunkname = "=udp",
		  .priv = PRIV_UDP, .devport = udpport, .devrecv = 1,
		  .what = "networking (udp)", .enabled = have_udp,
		  .capname = "udp" },
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
		/* raw ethernet frames, microvm only. Unlike tcp and udp
		 * above, which re-serve a stack the firmware already
		 * implements, this task owns a wire and nothing more --
		 * everything from arp upwards is Lua on the far side of its
		 * port (lib/eth.lua).
		 */
		{ .path = "/task/eth.lua", .chunkname = "=eth",
		  .priv = PRIV_ETH, .devport = 0, .devrecv = 0,
		  .what = "networking (raw ethernet)", .enabled = have_eth,
		  .capname = "eth" },
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
	}

	int pid = proc_new(code, len, "=init", is_file, 0, 0, PRIV_BOOT);

	if (pid < 0)
		return pid;

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
	for (i = 0; i < ndrivers; i++) {
		struct kproc *dp = pids[i] >= 0 ? find_proc(pids[i]) : 0;

		if (dp)
			grant_named(p, drivers[i].capname,
			    dp->rights[0].port, 0);
	}
	grant_named(p, "disk", diskport, 0);
	grant_named(p, "sched", schedport, 0);
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
static struct rqset rqsets[2];
static struct rqset *runq = &rqsets[0];
static struct rqset *donq = &rqsets[1];

static void
rq_init(void)
{
	for (int s = 0; s < 2; s++) {
		for (int i = 0; i < NRQ; i++)
			TAILQ_INIT(&rqsets[s].q[i]);
		rqsets[s].mask = 0;
		rqsets[s].n = 0;
	}
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

static void
make_ready(struct kproc *p)
{
	struct rqset *keep = p->onq;

	if (keep)
		rq_del(p);		/* pri is about to change; rebucket */
	p->status = READY;
	/* +1 because p has just been taken off its bucket and so is not in
	 * the count, but it is runnable and the fair share has to include it
	 */
	p->pri = reprioritize(p, count_runnable() + 1);
	/* a proc already waiting its turn keeps the lap it was in. one
	 * arriving fresh joins the current lap, which is how a mid-lap
	 * wakeup still gets a turn this lap.
	 */
	rq_add(keep ? keep : runq, p);
}

static int
count_runnable(void)
{
	/* the proc being resumed is on neither set -- dispatch takes it off
	 * before running it and puts it back after -- so it has to be
	 * counted here, or a proc asking about its own fair share leaves
	 * itself out of the divisor.
	 */
	int running = current_proc && current_proc->status == READY &&
	    !current_proc->onq;

	return runq->n + donq->n + running;
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
		ran = 1;
		ndispatch++;

		int nres = 0;

		current_proc = p;

		unsigned long long t0 = platform_ticks();

		p->resumed = t0;

		int rc = lua_resume(p->co, 0, p->nargs, &nres);

		p->nargs = 0;	/* first resume only; see struct kproc */

		p->cputime += platform_ticks() - t0;
		p->resumed = 0;
		current_proc = 0;

		/* a proc can run a full hook window (200k insns) before
		 * yielding; drain the 16-byte fifo now so it can't overflow
		 * between serial pumps.
		 */
		/* drain the 16-byte rx fifo, but on a deadline rather than
		 * after every resume.
		 *
		 * the hazard is real: a proc can run a full hook window
		 * before yielding, and the dispatch loop below can ping-pong
		 * two procs indefinitely without ever reaching the top of a
		 * lap, so pump_serial is not a bound on how long the fifo
		 * goes undrained. that is why this is here and not only up
		 * there.
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
		if (rc == LUA_OK)
			proc_kill(p, 0);
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

void
kernel_run(void)
{
	EFI_EVENT tick = 0;
	EFI_EVENT waits[2];
	UINTN index;
	int idle_polls = 0;
	int tick_slow = 0;
	int tick_fired = 0;

	/* periodic timer: idle becomes a real firmware sleep (hlt)
	 * instead of a hot stall-poll. the old "timer hangs the serial
	 * path" mystery was firmware console contention on com2, fixed
	 * by uart_takeover().
	 */
	if (BS->CreateEvent(EVT_TIMER, TPL_CALLBACK, 0, 0, &tick) !=
	    EFI_SUCCESS ||
	    BS->SetTimer(tick, TimerPeriodic, TICK_FAST_100NS) != EFI_SUCCESS)
		tick = 0;

	while (nlive > 0) {
		int ran = 0;

		nlaps++;

		/* CheckEvent consumes the signal, so this is also what
		 * re-arms tick_fired for the periodic timer.
		 */
		if (tick && BS->CheckEvent(tick) == EFI_SUCCESS)
			tick_fired = 1;

		expire_timers();
		pump_keyboard();
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
		/* see pump_net: paced to the tick so an idle machine can
		 * still reach the WaitForEvent sleep below. with no timer
		 * at all there's nothing to pace against, so fall back to
		 * pinging every lap.
		 */
		if (tick_fired || !tick) {
			pump_net();
			tick_fired = 0;
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
		 * independent of the priority function. every READY proc runs
		 * at most once and at least once per lap, whatever
		 * reprioritize() computes. a policy that is buggy, hostile or
		 * merely untuned can cost latency; it cannot wedge the
		 * machine. that matters because policy is exactly the part we
		 * expect to get wrong -- see AGENTS.md.
		 *
		 * plan 9 cannot do this: runproc() scans runq[] from the top
		 * and takes the first thing it finds, with no aging, so a
		 * high-basepri proc starves a low one indefinitely (which
		 * PriEdf > PriKproc > PriNormal makes deliberate). it has
		 * unbounded procs, so an exhaustive sweep would be O(nproc)
		 * per decision. MAXPROCS being small is what buys us the
		 * guarantee for free.
		 */
		/* phase one takes the highest priority first, so an
		 * interactive proc answers before a hog gets another turn.
		 * it is bounded by how many were waiting when the lap
		 * started, so it cannot spin on procs it keeps waking.
		 *
		 * phase two then drains whatever is left, priority not
		 * consulted -- including anything woken during phase one.
		 * that is the guarantee: every runnable proc runs at least
		 * once and at most once per lap, whatever reprioritize
		 * computes. a policy that is buggy, hostile or merely untuned
		 * costs latency and cannot wedge the machine, which matters
		 * because policy is the part we expect to get wrong.
		 *
		 * "already had its turn" is membership in donq rather than a
		 * per-lap marker, so nothing here is sized against MAXPROCS
		 * and nothing scans.
		 */
		int budget = runq->n;

		for (int i = 0; i < budget; i++) {
			struct kproc *p = rq_take_high(runq);

			if (!p)
				break;
			if (run_proc(p))
				ran = 1;
			if (p->status == READY)
				rq_add(donq, p);
		}

		for (;;) {
			struct kproc *p = rq_take_any(runq);

			if (!p)
				break;
			if (run_proc(p))
				ran = 1;
			if (p->status == READY)
				rq_add(donq, p);
		}

		/* the lap is over: what ran becomes what runs next. procs
		 * woken from here on join the new runq and so get a turn in
		 * the next lap rather than being lost.
		 */
		{
			struct rqset *t = runq;

			runq = donq;
			donq = t;
		}

		if (!ran) {
			/* everyone blocked: sleep until a key or the tick.
			 * tcp4 completion events are deliberately NOT in
			 * here -- WaitForEvent would consume their signaled
			 * state before net.c's own CheckEvent poll could see
			 * it (see kernel_new_net_event). the tick is what
			 * bounds how promptly a completion gets noticed.
			 */
			nidle++;
			if (tick) {
				UINTN n = 0;

				waits[n++] = ST->ConIn->WaitForKey;
				waits[n++] = tick;
				BS->WaitForEvent(n, waits, &index);
				/* woken by key or tick; either way the tick
				 * may have been what fired, and WaitForEvent
				 * consumed it. ping on the next lap.
				 */
				tick_fired = 1;
			} else
				BS->Stall(500);
		}
	}
}

/* disk gates write/append only (read is ambient, see stdio.c's
 * fopen): does whoever is currently resumed hold any right to
 * diskport? used from fopen, which has no lua_State at all --
 * liolib.c's io.open calls it as plain C, so current_proc is the
 * only way to learn who's asking.
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
	return proc_has_port(current_proc, diskport);
}
