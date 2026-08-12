/* mach-lite kernel: procs are isolated lua_States, ports are kernel
 * message queues, rights are per-proc handles onto ports. Lua sees no
 * pointers, and handle 0 is always a proc's own receive port. Preempted
 * on a count hook, so a busy loop cannot starve the machine.
 *
 * The dispatch loop and the device pumps live here. See docs/proc.md,
 * docs/ipc.md, docs/scheduling.md and docs/serialize.md.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "efi.h"
#include <sys/queue.h>

#include "kernel.h"
#include "kproc.h"
#include "serialize.h"
#include "cpu.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "buf.h"
#include "luaheap.h"
#include "debug.h"
#include "platform.h"

/* MAXPROCS and MAXPORTS come from the platform's param.h: what is
 * headroom on a machine with gigabytes is a large share of a board's
 * ram. Ceilings, not reachable counts -- see docs/proc.md.
 */
#include "param.h"

#ifndef MAXPROCS
#error "platform param.h must define MAXPROCS"
#endif
#ifndef MAXPORTS
#error "platform param.h must define MAXPORTS"
#endif

/* fallback if calibration fails; normally replaced at boot by a measured
 * value -- see calibrate_reductions().
 */
#define REDUCTIONS	25000
#define MAXWEIGHT	16	/* sys.set_priority clamp -- see kernel_run's WRR loop */
#define MAXTIMERS	128	/* outstanding one-shot timers, machine-wide */
/* floor on phase two's dispatch bound. The bound is what ends a lap at
 * all: two procs feeding each other hand phase two a fresh proc every
 * time it takes one. Sized to amortize the fixed cost between laps, not
 * merely to terminate -- see docs/scheduling.md.
 */
#define LAPSPILL	64

/* how much a proc must have allocated before its collector is stepped.
 * Below this the step costs more than it can recover: a proc that did
 * almost nothing in its slice has almost nothing to collect.
 */
#define GCSTEP_MIN	(16 * 1024)
/* the largest step gc_step asks for, in kilobytes: enough to keep lua's
 * debt inside a 32-bit l_mem.
 */
#define GCSTEP_MAX_KB	(16 * 1024)
/* fair-share averaging window. The mixing weight is n/D, which
 * approximates an exponential only while n stays small next to D, so
 * this must stay well above the lap period -- see docs/scheduling.md.
 */
#define SCHED_DECAY_MS	500
/* wall-clock slice a proc may hold before the count hook yields it. A
 * slice costs one lap, so this decides how much of the machine goes to
 * scheduling rather than to work. A platform whose lap is expensive
 * overrides it in param.h -- see docs/scheduling.md.
 */
#ifndef QUANTUM_MS
#define QUANTUM_MS	2
#endif
/* priority resolution per unit of weight. plan 9's PriNormal is 10 and
 * its bands run 0..19; weight is our basepri, so this is what gives a
 * default-weight proc a 0..10 range to move in rather than 0..1.
 */
#define PRI_BASE	10

/* proc states. see docs/proc.md */
enum {
	DEAD,
	READY,

	/* waiting on a port, and carries a waiter naming it. */
	BLOCKED,

	/* died of an error, held so something can read it. holds no
	 * rights, but the lua_State still stands, so every frame at the
	 * moment of death is there.
	 */
	BROKE,

	/* made but never run. waits on its creator rather than on a port,
	 * so nothing but its creator can make it runnable.
	 */
	HATCHING,

	/* a debugger holds it: on no queue, resumed by dbg.cont. not
	 * kproc.frozen, which keeps the proc queued.
	 */
	STOPPED,
};
/* device capabilities, one per class of hardware a proc may reach. */
enum {
	PRIV_NONE,

	/* proc 0 and nothing else. not a device capability: it means raw
	 * ESP access reaches this proc, which is what lets it build the
	 * root namespace every other proc inherits.
	 */
	PRIV_BOOT,

	PRIV_ESP,
	PRIV_CONS,
	PRIV_WIRE,
	PRIV_POWER,
	PRIV_P9,
	PRIV_ETH,
	PRIV_FB,
	PRIV_BLK,
	PRIV_FLASH,
};

/* the last N lines a proc executed, in a ring. Off by default: a line
 * hook fires per line, so the cost per entry decides what a traced proc
 * runs like. Allocated only while a trace is armed, and sized so one
 * directory listing fits without wrapping. See docs/proc.md.
 */
#define TRACEMAX	16384

static void
msgbufs_free(struct msgbufs *b)
{
	for (int i = 0; i < b->n; i++)
		if (b->p[i])
			platform_chunk_free(b->p[i], b->len[i]);
	b->n = 0;
}

/* what these bytes cost a queue, on top of the serialized message */
static size_t
msgbufs_bytes(const struct msgbufs *b)
{
	size_t t = 0;

	for (int i = 0; i < b->n; i++)
		t += b->len[i];
	return t;
}

/* procs live on the heap too. a dead one keeps its slot until the reaper
 * runs at the top of a lap, because dispatch reads its status right after
 * a resume that may have killed it -- freeing inside proc_kill would hand
 * dispatch a dangling pointer.
 */
static struct kproc *procv[MAXPROCS];
static int prochigh;
/* ports live on the heap; this is the index that names them. The wire
 * carries the index, not a pointer, so a message stays one size and a
 * port keeps its identity if its body moves.
 */
/* the lock over everything shared between procs: the port and proc
 * index tables, every port's messages and waiters, the refcounts that
 * decide when a port dies, and the rights a sender mints into a
 * receiver's table. Buckets hashed on port index, taken caller-holds.
 * Read docs/locking.md before narrowing a caller to one bucket.
 */
#define NIPCLOCK 8

struct ipcbucket {
	struct lock lk;
	/* atomic because ipclock_enter_one's fast path reads it without
	 * the lock. Relaxed is enough: a cpu is the only writer of its
	 * own value, so a racing read can be stale but never wrongly
	 * equal to me. depth is owner-only, so it needs none of that.
	 */
	_Atomic(struct cpu *) owner;
	int depth;

	/* how long it is held, summed. lock.h counts the waiting; these
	 * two together say whether splitting further would buy
	 * anything. Owner-only, like depth.
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

/* does this cpu hold this bucket. Not lock.h's holding(), which answers
 * for the machine: under smp another cpu holding a bucket is ordinary
 * and says nothing about whether this one may touch the ports under it.
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

/* any bucket at all. The weakest of the three, for a helper that needs
 * its caller to be inside an ipc region rather than to cover a named
 * port -- proc_block, which records a decision a bucket held still.
 */
static int
ipcheld_any(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		if (ipcheld_one(&ipcbuckets[i]))
			return 1;
	return 0;
}

/* what the inner helpers assert, after OpenBSD's MUTEX_ASSERT_LOCKED.
 * Live on every platform: the owner is recorded even where NCPU is 1.
 * Reach for IPC_ASSERT_PORT in a helper that touches one named port --
 * it is the weaker demand, and marks a caller the buckets can narrow.
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

/* recursive by need: a receive holds the lock across a deserialize,
 * which allocates, which can run a __gc handler that closes a handle.
 *
 * Pitfall: a bucket whose owner is set but whose leave is missed is
 * never released, and every later acquire on that cpu takes the depth
 * fast path and succeeds. The kernel runs unlocked and the whole suite
 * passes. Trust kernel_run's no-bucket-held assertion, not the tests.
 */
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
void
ipclock_enter_port(struct kport *p)
{
	ipclock_enter_one(ipcbucket_of(p));
}

void
ipclock_leave_port(struct kport *p)
{
	ipclock_leave_one(ipcbucket_of(p));
}

/* every bucket, ascending, which is the order two locks of one class
 * are taken in everywhere. Release order is free.
 */
void
ipclock_enter(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		ipclock_enter_one(&ipcbuckets[i]);
}

void
ipclock_leave(void)
{
	for (unsigned i = NIPCLOCK; i-- > 0; )
		ipclock_leave_one(&ipcbuckets[i]);
}

struct kport *portv[MAXPORTS];
static int porthigh;		/* one past the highest slot ever used */
/* stamped into every port so a slot can be told from the port in it;
 * see kport.gen. 64-bit and incremented once per port, so it does not
 * wrap in any run this machine could have.
 */
static unsigned long long portgen;
static struct kport *kbdport;

/* the second terminal's keys, where the machine has a keyboard that is
 * not the console. Separate from kbdport: two terminals sharing one
 * input port race for every keystroke.
 */
static struct kport *devkbdport;

/* the pointer's events, where the machine has one. Its own port for the
 * same reason: two readers would each see half of a drag.
 */
static struct kport *devptrport;
static int nlive;

static int nextpid;

/* the machine-wide heap, where NCPU is 1. Null above that, and that is
 * the test for whether a proc owns the heap it points at. The
 * arrangement follows NCPU rather than platform_ncpu() -- see
 * docs/proc.md, which is worth reading before changing that.
 */
static struct luaheap *shared_heap;

/* the disk capability. A reserved port that carries no message: holding
 * any right to it is what fopen checks. It gates write and append only,
 * because a stray read corrupts nothing and the threat model is buggy
 * lua rather than a hostile user. See AGENTS.md on non-goals.
 */
static struct kport *diskport;

/* the scheduling capability, same shape as diskport: a kernel-owned
 * port that is never sent to or received from. holding a right to it
 * IS the authorization -- see api_set_priority.
 */
static struct kport *schedport;

/* the clock capability, the same shape -- see api_settime. */
static struct kport *clockport;

/* the debug capability, the same shape again -- see may_debug. a right
 * to it debugs any proc, which is what reaches a boot service: nothing
 * holds a right to init's children but init.
 */
static struct kport *dbgport;

static int proc_has_port(struct kproc *p, struct kport *port);

static int port_push(struct kport *port, const unsigned char *data,
    size_t len, const unsigned short *refs, int nrefs);
struct msgbufs;
static int port_push_owned(struct kport *port, unsigned char *data,
    size_t len, const unsigned short *refs, const unsigned char *refrecv,
    int nrefs, const struct msgbufs *bufs);

extern unsigned long long platform_ticks(void);

/* the C heap's own accounting, per platform.
 *
 * Not named malloc_stats: that is a libc symbol, and a platform linking
 * a libc resolves it to one that takes no arguments and does nothing,
 * leaving the out-params holding whatever was on the stack. Nothing
 * warns, because the linker is happy to match the name.
 */
extern void kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
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
 * touches them needs this. It exists because the alternative is
 * silence: a queue mutated from a syscall while another cpu is in
 * dispatch hands one proc to two cpus, and that surfaces much later as
 * a fault on a good pointer, or as lua refusing to resume.
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
	/* caller holds ipclock, unless there is nothing to release. The
	 * empty case is the common one: a message carrying no rights
	 * names no port, so this touches nothing and may be called from
	 * anywhere -- which is what lets an ordinary message be disposed
	 * of without leaving one bucket to take all eight.
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
int right_new(struct kproc *p, struct kport *port, int recv);

/* the eth task's wakeup, and the only device port here driven by an
 * interrupt rather than a poll. Pushed only when a device signals, so a
 * machine with a quiet wire sleeps instead of asking.
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
 * The hook yields on elapsed time, so this is a sampling rate rather
 * than a slice length, and a proc overshoots its quantum by at most one
 * period. Measured at boot so the period stays a fixed fraction of the
 * quantum on any machine -- see docs/scheduling.md.
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

/* the clock half of calibration, separate so it can run first: until it
 * has, there is no clock to stamp a log line with. The epoch is taken
 * before the stall, so calibration counts as real boot time rather than
 * vanishing from anyone's boot latency measurement.
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

/* The wall clock: unix seconds at boot, all a machine with no battery
 * keeps. Unset reads as nil, not 1970. Locked because a 64-bit store
 * is not atomic on every target, and a torn read is another century.
 */
static struct lock timelock = LOCK_INIT;
static long long wall_base_s = -1;	/* unix seconds at boot, or -1 */

/* unix seconds, or 0 when the clock has never been set. */
long long
kernel_walltime(void)
{
	long long base, up = (long long)uptime_ms() / 1000;

	lock(&timelock);
	base = wall_base_s;
	unlock(&timelock);
	return base < 0 ? 0 : base + up;
}


/* one-shot timers. sys.timer(ms) mints a port, hands the caller its
 * receive right, and records a deadline here; expire_timers pushes one
 * message when the deadline passes and lets the port go. A timer is a
 * port so that recv-with-timeout falls out of thread.alt with no new
 * api, as thread.alt({{port = reply}, {port = sys.timer(500)}}).
 *
 * A flat unsorted array, scanned once per lap. Resolution is the
 * scheduler tick, so a timer fires up to one tick late and never early.
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
	/* caller holds ipclock: expire_timers already has it, api_timer
	 * must take it.
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

/* the transcript, in the kernel because the earliest producers are here
 * and because a task can die. A cursor is logseq -- bytes ever written,
 * not a ring offset -- so a reader that fell behind is told what it lost.
 */
#define LOGRING	(32 * 1024)
#define LOGLINE	1024		/* one line, truncated as syslog truncates */
#define LOGCHUNK 2048		/* the most one sys.dmesg call copies */

static char logring[LOGRING];
static unsigned long long logseq;	/* bytes ever written */
static unsigned long long loglost;	/* bytes overwritten unread */
static struct lock loglock = LOCK_INIT;

static unsigned long long
logoldest(void)
{
	return logseq > LOGRING ? logseq - LOGRING : 0;
}

/* Nothing in here may log: the gc error path calls kernel_log, and a
 * second entry with the lock held would sit on itself forever.
 */
static void
logput(const char *s, size_t n)
{
	if (n == 0)
		return;
	if (n > LOGRING) {		/* LOGLINE bounds every caller */
		s += n - LOGRING;
		n = LOGRING;
	}
	lock(&loglock);

	unsigned long long before = logoldest();
	size_t w = (size_t)(logseq % LOGRING);
	size_t first = LOGRING - w < n ? LOGRING - w : n;

	memcpy(logring + w, s, first);
	if (first < n)
		memcpy(logring, s + first, n - first);
	logseq += n;
	loglost += logoldest() - before;
	unlock(&loglock);
}

/* one stamped diagnostic line, terminated here so callers cannot forget.
 *
 * the format is shared with lib/log.lua: two producers, one transcript.
 * the stamp is taken when the line is emitted, which matters because a
 * proc reaching the console through a port is delivered later than this
 * synchronous path -- so display order and real order differ, and only
 * the stamps recover it.
 */
void
kernel_log(const char *s)
{
	unsigned long long ms = uptime_ms();
	char buf[320];
	int n = snprintf(buf, sizeof buf, "[%5llu.%03llu] %s\n", ms / 1000,
	    ms % 1000, s);

	kputs(buf);
	logput(buf, n < 0 ? 0 : (size_t)n >= sizeof buf ? sizeof buf - 1 :
	    (size_t)n);
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
			port->gen = ++portgen;
			port->used = 1;
			TAILQ_INIT(&port->waiters);
			portv[i] = port;
			if (i >= porthigh)
				porthigh = i + 1;
			return port;
		}
	return 0;
}

/* has this proc room for another port?
 *
 * asked before the table is searched, so a proc over its limit costs
 * nothing to refuse and cannot take the last free slot from one still
 * under. the count itself is kept by right_new and right_drop, which is
 * where a receive right is gained and lost.
 */
static int
port_budget_left(struct kproc *p)
{
	return !p->port_limit || p->nports < p->port_limit;
}

/* the port behind this proc's handle 0, or null if it has gone.
 *
 * see kproc.selfidx: the pair is checked rather than a pointer chased,
 * so a portv slot reused since says no instead of yes about a stranger.
 */
static struct kport *
proc_selfport(struct kproc *p)
{
	if (!p->selfgen)
		return 0;

	struct kport *port = portv[p->selfidx];

	if (!port || port->gen != p->selfgen)
		return 0;
	return port;
}

static void port_unref(struct kport *port);

/* free one message: the in-flight right refs it carries, and any
 * transferred buffer nobody took.
 */
static void
msg_free(struct kmsg *m)
{
	release_inflight(m->refs, m->refrecv, m->nrefs);
	msgbufs_free(&m->bufs);
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
struct right *
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

int
right_new(struct kproc *p, struct kport *port, int recv)
{
	/* The one helper here that needs no lock. p's right table belongs
	 * to p, and only p runs at a time; port->nrights is atomic, and
	 * taking a reference destroys nothing, because the caller already
	 * holds one. That is what lets deserialize run outside every
	 * bucket, which it must: building lua values allocates.
	 *
	 * Start where a free slot was last seen, or a proc holding many
	 * rights rescans all of them for each new one.
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
			if (recv) {
				port->nrecv++;
				/* what this proc is charged for; see
				 * kproc.nports
				 */
				if (++p->nports > p->nports_peak)
					p->nports_peak = p->nports;
			}
			p->rhint = i + 1;
			if (i + 1 > p->rhigh)
				p->rhigh = i + 1;
			return i;
		}
	}
	return -1;
}

void
right_drop(struct kproc *p, struct right *r)
{
	/* caller holds ipclock. */
	IPC_ASSERT_LOCKED();
	struct kport *port = r->port;

	r->used = 0;
	if (r->recv) {
		port->nrecv--;
		if (p->nports > 0)
			p->nports--;
	}
	port_unref(port);
}

/* grant a named capability: take a right the ordinary way and record
 * its name in the proc's grant list, so lua can find the handle through
 * sys.granted(). A null port is a no-op, which is the "not this boot"
 * case. The list has no ceiling: a fixed array silently drops grants
 * past its size, and a missing grant reads as a broken device.
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
			right_drop(p, r);
		return;
	}
	g->name = name;
	g->handle = h;
	SLIST_INSERT_HEAD(&p->grants, g, e);
}

struct right *
right_get(struct kproc *p, lua_Integer h)
{
	struct right *r = right_slot(p, (int)h);

	if (!r || !r->used)
		return 0;
	return r;
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
 * This is the wide operation: it reaches every port the proc waits on,
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

/* collect the waits left over from the last block, on the proc's own cpu
 * and just before it is resumed. The waker holds one port's bucket, so
 * it unlinks only the entry it woke on; a proc in an alt is on several,
 * and collects the rest here, one bucket at a time. Linux's poll splits
 * pollwake and poll_freewait the same way round.
 *
 * Also where `woken` is cleared, which re-arms the proc to be claimed
 * the next time it blocks. Nothing can claim it in between, because a
 * running proc is not BLOCKED.
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

/* how the claim goes, reported through sys.stats().lock.ipc. Losing
 * counts the times two ports reached one alt-blocked proc at once, so
 * it says how much of an alt set is live at the same moment.
 *
 * It is also the only evidence the losing branch runs at all: it is
 * reachable on more than one cpu and never on one, so a suite that
 * exercises it by accident stops the moment scheduling shifts. A test
 * asserts this counter is nonzero for that reason.
 */
static atomic_ullong claim_won, claim_lost;

/* take the right to wake this proc, or find that another port already
 * has. See kproc.woken.
 */
static int
wake_claim(struct kproc *p)
{
	int expect = 0;

	if (atomic_compare_exchange_strong_explicit(&p->woken, &expect, 1,
	    memory_order_acq_rel, memory_order_relaxed)) {
		atomic_fetch_add_explicit(&claim_won, 1, memory_order_relaxed);
		return 1;
	}
	atomic_fetch_add_explicit(&claim_lost, 1, memory_order_relaxed);
	return 0;
}

static void
wake_receivers(struct kport *port)
{
	/* caller holds the bucket covering `port`. Touches another proc's
	 * run queue and this port's waiter list, but no other port's,
	 * which is what lets a sender hold one bucket.
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

/* the mirror of wake_receivers: anyone parked for room on this port.
 * Draining a message is the ordinary wakeup; a port dying is the other,
 * and without it a writer blocked on a full port whose reader vanished
 * sleeps forever. A spurious wake is harmless, since sys.sendblock only
 * promises the port might have room and every caller loops.
 */
static void
wake_senders(struct kport *port)
{
	/* caller holds the bucket covering `port`. */
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

/* queue a message, taking ownership of `data` only when it returns 0. A
 * dead port drops it silently: the sender learns from a monitor, not
 * from the send. refs/nrefs are in-flight right refs, and may be null.
 *
 * On any refusal the caller still owns the buffer and the refs, and
 * must free the one and release the other. That is deliberate: this
 * runs under one bucket, and releasing a reference can flush a queue,
 * which reaches ports under other buckets and so demands all of them.
 * A narrow region cannot widen, so disposal waits for the caller.
 */
static int
port_push_owned(struct kport *port, unsigned char *data, size_t len,
    const unsigned short *refs, const unsigned char *refrecv, int nrefs,
    const struct msgbufs *bufs)
{
	/* caller holds the bucket covering `port`. */
	IPC_ASSERT_PORT(port);
	if (port->dead) {
		port->ndrop_dead++;
		cpu_self()->ndrop_dead++;
		return -3;
	}

	/* transferred bytes count against the queue too. They are not in
	 * the message, so without this a sender could park megabytes on a
	 * queue nobody drains and MAXQUEUE would read as empty.
	 */
	size_t cost = len + (bufs ? msgbufs_bytes(bufs) : 0);

	if (port->qbytes + cost > MAXQUEUE) {
		port->ndrop_full++;
		cpu_self()->ndrop_full++;
		return -2;		/* full, distinct from out of memory */
	}

	struct kmsg *m = malloc(sizeof *m);

	if (!m)
		return -1;
	m->next = 0;
	m->len = len;
	m->qcost = cost;
	m->data = data;
	m->nrefs = nrefs;
	if (bufs)
		m->bufs = *bufs;
	else
		m->bufs.n = 0;
	for (int i = 0; i < nrefs; i++) {
		m->refs[i] = refs[i];
		m->refrecv[i] = refrecv ? refrecv[i] : 0;
	}
	if (port->tail)
		port->tail->next = m;
	else
		port->head = m;
	port->tail = m;
	port->qbytes += cost;
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

	int rc = port_push_owned(port, copy, len, refs, 0, nrefs, 0);

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

/* Strip debug members a confined proc turns outward: sethook (the
 * preemption hook), and on a los.sys C closure getupvalue/setupvalue
 * (kernel-pointer leak, syscall redirect, right forge). traceback and
 * getinfo stay, read-only; boot keeps the whole library. */
void
kernel_strip_debug(lua_State *L)
{
	static const char *const gone[] = {
		"sethook", "getupvalue", "setupvalue", "upvalueid",
		"upvaluejoin", "setlocal", "setmetatable", "getregistry",
		"getuservalue", "setuservalue", NULL
	};

	if (!lua_istable(L, -1))
		return;
	for (int i = 0; gone[i]; i++) {
		lua_pushnil(L);
		lua_setfield(L, -2, gone[i]);
	}
}

/* load() with the binary door shut: mode forced to "t", so a bytecode
 * chunk is rejected by checkmode instead of reaching the unverified
 * luaU_undump against the kernel heap. Original load is upvalue 1. */
static int
confined_load(lua_State *L)
{
	if (lua_gettop(L) < 3)
		lua_settop(L, 3);	/* pad chunk, name, mode; keep env */
	lua_pushliteral(L, "t");
	lua_replace(L, 3);		/* text only, dropping any 'b' */

	int n = lua_gettop(L);

	lua_pushvalue(L, lua_upvalueindex(1));
	lua_insert(L, 1);
	lua_call(L, n, LUA_MULTRET);
	return lua_gettop(L);
}

/* wrap load() and drop string.dump in a non-boot proc. Same door as
 * loadfile/dofile, which proc_new removes outright: a chunk off the
 * disk and a chunk of bytecode are the one hole wearing two names.
 */
void
kernel_confine_load(lua_State *L)
{
	lua_getglobal(L, "load");
	if (lua_isfunction(L, -1)) {
		lua_pushcclosure(L, confined_load, 1);
		lua_setglobal(L, "load");
	} else {
		lua_pop(L, 1);
	}

	lua_getglobal(L, "string");
	if (lua_istable(L, -1)) {
		lua_pushnil(L);
		lua_setfield(L, -2, "dump");
	}
	lua_pop(L, 1);
}

/* Confine a non-boot proc. Called protected: lua_getglobal fires _G's
 * lazy loader, which allocates, and proc_new has no error handler -- a
 * failed allocation here aborts the machine, not the spawn.
 */
static int
confine_proc(lua_State *L)
{
	/* referencing "io" here also FORCES the lazy load, so the table
	 * exists and is stripped rather than being created fresh (and
	 * whole) at first use.
	 */
	lua_getglobal(L, "io");
	kernel_strip_io(L);
	lua_pop(L, 1);

	lua_getglobal(L, "debug");
	kernel_strip_debug(L);
	lua_pop(L, 1);

	/* loadfile/dofile off the disk, load "b" out of a string: one
	 * hole, three names. confine_load forces text and drops
	 * string.dump.
	 */
	lua_pushnil(L);
	lua_setglobal(L, "loadfile");
	lua_pushnil(L);
	lua_setglobal(L, "dofile");
	kernel_confine_load(L);
	return 0;
}

/* collectgarbage with the verb ignored: one full collect, never a
 * restart. The kernel owns the schedule (GCSTOP, gc_step); a restart
 * would let a finalizer run mid-allocation. GCCOLLECT keeps the stop.
 */
static int
confined_collectgarbage(lua_State *L)
{
	lua_gc(L, LUA_GCCOLLECT);
	lua_pushinteger(L, 0);	/* what collectgarbage("collect") returns */
	return 1;
}

/* replace collectgarbage in every proc, boot included. */
void
kernel_confine_gc(lua_State *L)
{
	lua_pushcfunction(L, confined_collectgarbage);
	lua_setglobal(L, "collectgarbage");
}

int
kernel_current_is_boot(void)
{
	return cpu_self()->current && cpu_self()->current->priv == PRIV_BOOT;
}

/* ---- coroutine.wrap, made transparent to preemption ----
 *
 * The hook yields whatever state is running, and a yield unwinds to
 * that state's resumer. For a generator that is whoever called it, and
 * `for v in seq(n)` reads a yield of no values as the generator being
 * finished: the loop ends early and hands back short data, no error. So
 * resume again rather than believe the yield. Yielding ourselves first
 * keeps that from defeating the preemption it hides, and marks this
 * state preempted, so nested wraps compose.
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

/* serialize the value at `idx` and queue it on r's port. Shared by
 * api_send and api_call, which differ only in what follows. The wbuf is
 * disposed of on every path.
 *
 * It takes no lock on entry, which is the point: serializing allocates
 * lua memory and the collector reaches api_close from there, so it must
 * not run under a bucket. Only the queue insert and the wakeup do. The
 * refs the serializer mints keep every port the message names alive
 * meanwhile.
 */
enum { SEND_OK = 0, SEND_UNSERIALIZABLE, SEND_DEAD, SEND_FULL, SEND_NOMEM };

/* `len`, if given, is filled with the serialized size of the message.
 * On SEND_FULL that is what a caller needs to wait for room: only the
 * kernel can know the figure, so lua never has to estimate one. See
 * api_sendblock for what asking for zero bytes costs.
 */
static int
port_send_from_lua(lua_State *L, struct kproc *p, struct right *r, int idx,
    size_t *len)
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

	/* what the queue will charge, which is what a waiter has to wait
	 * for room for: the message, plus the bytes it hands over.
	 */
	if (len)
		*len = w.len + msgbufs_bytes(&w.bufs);

	ipclock_enter_port(r->port);
	rc = port_push_owned(r->port, w.p, w.len, w.refs, w.refrecv, w.nrefs,
	    &w.bufs);
	ipclock_leave_port(r->port);

	switch (rc) {
	case 0:
		/* queued, so the bytes are the message's now. Until this
		 * point the sender still had them, which is what makes a
		 * refused send leave the sender whole.
		 */
		for (int i = 0; i < w.bufs.n; i++)
			luabuf_detach(L, w.bufown[i]);
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
	size_t len = 0;
	int rc;

	luaL_checkany(L, 2);				/* raises; before */

	/* no lock here at all: the right lookup reads this proc's own
	 * table, which only this proc touches, and port_send_from_lua
	 * takes the one bucket it needs for as long as it needs it.
	 */
	r = right_get(p, h);
	rc = r ? port_send_from_lua(L, p, r, 2, &len) : 0;

	if (!r)
		return luaL_error(L, "bad right");

	if (rc == SEND_UNSERIALIZABLE)
		return luaL_error(L, "unserializable message");
	if (rc == SEND_DEAD) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "dead");
		return 2;
	}

	/* a full queue returns rather than raising, so the caller picks a
	 * policy for it. The kernel must not pick: it cannot tell a pipe
	 * write from a server reply, and blocking here would let one slow
	 * reader wedge a server for every other client. Same split the
	 * receive side makes, with the loop living in lua.
	 *
	 * The third value is how many bytes were refused, so that policy
	 * can be "wait for room" without lua working out how much.
	 */
	if (rc == SEND_FULL) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "full");
		lua_pushinteger(L, (lua_Integer)len);
		return 3;
	}
	if (rc == SEND_NOMEM)
		return luaL_error(L, "out of memory queueing message");
	lua_pushboolean(L, 1);
	return 1;
}

/* A proc about to block holds no waits: a blocked proc is not running,
 * so it cannot ask to block again. Reaching here with waits attached
 * means the last block never stopped this proc -- a yield that did not
 * unwind to the kernel. One port then carries two waiters for one proc,
 * and the waker walks an entry wait_clear has freed.
 *
 * The test sits at each call site rather than in a helper: it reads
 * shared state and belongs inside the region guarding wait_add, while
 * the raise must sit outside it, because luaL_error jumps.
 */
#define BLOCKED_TWICE_MSG "already blocked (sys.block from a coroutine? " \
	"use los.thread's park)"

/* a park must be issued from the state the kernel resumed. A yield
 * unwinds to the resumer of the state it fired in, so a block from a
 * coroutine below p->co lands in whoever resumed that, while this proc
 * is already marked BLOCKED and off the run queue -- surfacing later as
 * a protocol stalling somewhere else. Threads are safe: lib/thread
 * parks by yielding to thread.run, which blocks from the top.
 *
 * Checked at entry, not where the proc is descheduled: a call that
 * finds its message waiting would not park, but is still wrong.
 */
static void
nopark(lua_State *L, struct kproc *p)
{
	if (L != p->co)
		luaL_error(L, "illegal parking: this coroutine is not the "
		    "one the kernel resumed, so a block here would never "
		    "reach it");
}

/* sys.sendblock(h, need) -- block until the port might have room for a
 * message of `need` bytes. Needs only a send right, and `need` defaults
 * to zero, which asks whether there is any room at all.
 *
 * Pass the real size. A message that is a large fraction of MAXQUEUE is
 * refused while the queue still reports room, so a caller asking for
 * zero wakes, fails to send, and parks again -- burning its slice
 * instead of sleeping. A `need` above MAXQUEUE returns rather than
 * sleeping forever, and lets the send report the failure.
 */
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

	/* narrowed to one bucket, and it qualifies on both counts:
	 * everything below names r->port alone, and nothing below
	 * allocates lua memory. The right lookup comes first because it
	 * says which bucket to take, which is sound because a proc's own
	 * right table is touched only while that proc runs.
	 *
	 * The room test and the wait_add are one region: a receiver
	 * draining between them would wake nobody, leaving this proc
	 * parked on a port that has the room it asked for.
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
		port->qbytes -= m->qcost;
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

/* push a popped message as one lua value, and dispose of it.
 *
 * returns nonzero having pushed nothing: -1 for a message this cannot
 * be, -2 for one it could not receive (a full rights table). A -2 loses
 * any rights the same message already installed.
 */
static int
msg_to_lua(lua_State *L, struct kproc *p, struct kmsg *m)
{
	size_t off = 0;
	struct minted mt = { .n = 0 };
	/* the reason is kept as deserialize gave it, so popfail can tell a
	 * proc that ran out of rights from a message that would not decode.
	 */
	int rc = deserialize(L, m->data, m->len, &off, &m->bufs, p, 0, &mt);

	/* a message arrives whole or not at all. a partial walk has
	 * already minted rights the receiver was never told the numbers
	 * of, so it could not close them and they would be lost for its
	 * lifetime -- which a sender controls, and so could repeat.
	 */
	if (rc)
		minted_undo(p, &mt);

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
	if (rc == -2) {
		if (p->bufdenied) {
			p->bufdenied = 0;
			return luaL_error(L, "no room for a transferred "
			    "buffer");
		}
		return luaL_error(L, "out of rights: %d of %d in use",
		    p->rhigh, MAXRIGHTS);
	}
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
 * The client half of an rpc in one kernel entry: send on h, then block
 * on replyh. It is also the only shape that can hand off straight to
 * the receiver, which needs the kernel to know at send time that the
 * sender is about to sleep on a named port. Send failures report nil
 * plus "dead" or "full", as sys.send does; a hung-up reply port reports
 * "hungup" rather than waiting. Not a timeout -- no deadline tells a
 * slow server from a broken one.
 */

/* may this proc act on that one? Holding a right to the target's self
 * port is the authority, and that port outlives the proc's own right to
 * it, so this answers for a corpse too.
 *
 * It gates what acts on a proc, not what reads one: sys.stack, sys.trace
 * and sys.pidstat stay ambient, because what they report is structure
 * rather than a proc's data. sys.set_trace is on this side because it
 * writes -- it reallocates a ring the target's own hook is filling.
 */
static int
may_control(struct kproc *p, struct kproc *target)
{
	struct kport *port = proc_selfport(target);

	return port && proc_has_port(p, port);
}

/* is this proc the only holder of a right to `port`? That is our eof.
 * It counts every right the proc holds rather than testing nrights
 * against one, because a caller may hold several to one port -- a reply
 * port is a receive right to wait on plus a send right to publish -- and
 * a right it holds itself cannot answer it. sys.hungup must ask the same
 * question, or the two disagree about when a server has gone.
 */
static int
sole_holder(struct kproc *p, struct kport *port)
{
	int mine = 0;

	for (int i = 0; i < p->rhigh; i++) {
		struct right *q = right_slot(p, i);

		if (q && q->used && q->port == port)
			mine++;
	}
	return port->nrights <= mine;
}

static int
call_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	struct right *rr;

	(void)status;

	ipclock_enter();
	rr = right_get(p, (int)ctx);
	/* re-resolved rather than carried across the yield: a handle is an
	 * index into a table this proc can rearrange, and the right behind
	 * it may have moved. A miss is ordinary, not a bug -- the port can
	 * be torn down by the last other right going away while we parked.
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
		if (sole_holder(p, rr->port)) {
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
	size_t len = 0;
	int rc = port_send_from_lua(L, p, r, 2, &len);

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
	/* the refused size third, as sys.send reports it, so a caller whose
	 * policy is to wait has the figure without sending twice to learn
	 * it.
	 */
	if (rc == SEND_FULL) {
		lua_pushnil(L);
		lua_pushliteral(L, "full");
		lua_pushinteger(L, (lua_Integer)len);
		return 3;
	}
	/* the reply may already be queued -- a same-proc service, or one
	 * that ran between our send and here -- in which case call_k takes
	 * it without yielding at all.
	 */
	return call_k(L, LUA_OK, (lua_KContext)rh);
}

/* an alt set may carry send waits as well as receive waits: sends[i] is
 * the size entry i wants room for, and anything else makes entry i an
 * ordinary receive. A parallel table rather than a box per entry, so
 * the common all-receive call passes nothing extra and builds no
 * garbage. -1 means "not a send wait", since a send of zero bytes is a
 * real question.
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

/* which entry of the handle table at stack index 1 is ready, or 0 for
 * none. The index rather than the handle, so the caller can find it
 * again in the table it passed.
 *
 * Advisory, and it must stay that way: it answers a level question,
 * which goes stale the moment a second cpu exists. Every caller
 * re-checks with a real receive and parks again if it lost the race, so
 * a wrong answer costs a wasted wake and can never lose a message.
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
 * loses a reference. A ready-port hint can never name a hangup, because
 * the thread that must notice its peer is gone has nothing queued. So a
 * scheduler watches this instead, at one compare per pass, and wakes
 * everyone only when the answer to sys.hungup could have changed.
 *
 * Machine-wide rather than per-port: it is a "go look" edge, and the
 * looking is sys.hungup.
 */
static int
api_hangups(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)hangup_gen);
	return 1;
}

/* sys.anyready() -> bool. Does any port this proc can receive on have a
 * message waiting? The question a runnable proc cannot otherwise ask: a
 * push wakes whoever is parked, which does nothing for a proc already
 * running, so a thread that never parks would not learn that a message
 * arrived for a parked sibling.
 *
 * Coarser and much cheaper than sys.altpoll -- no table, just a scan of
 * this proc's own rights. It answers "is a sweep worth doing", so a
 * scheduler can ask every round and pay for altpoll only when it is.
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

/* take the first available message from a set of receive rights, never
 * having merely looked at one. Peeking answers a level question that
 * goes stale as soon as a second cpu exists, and the answer is not a
 * better peek but holding the port across the check and the dequeue.
 * Go's chansend and 9front's altexec both do this; neither ever wakes a
 * waiter to let it look for itself.
 *
 * Returns index, message. The index is into the caller's own table, so
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

	/* the whole scan is one region. The loop adds a waiter to each
	 * port as it goes, so a sender to the first could wake this proc
	 * and clear its waiters while the loop is still adding more --
	 * leaving it asleep, already woken, with its message on a port it
	 * no longer waits on. A hang, not a wrong answer.
	 *
	 * Nothing that raises may run in here, so a handle is read with
	 * lua_tointegerx and a bad one is reported below as an outcome.
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
	/* Required, not optional. A tag that may be left out is a tag
	 * that is left out at exactly the call site that later leaks.
	 */
	const char *tag = luaL_checkstring(L, 1);
	const char *where;

	luaL_where(L, 1);
	where = lua_tostring(L, -1);
	if (!where || !*where)
		where = "?";

	/* both allocations inside one region, and the errors raised
	 * outside it: luaL_error longjmps, so nothing that raises may
	 * run while this is held.
	 */
	int over;

	ipclock_enter();
	over = !port_budget_left(p);
	port = over ? 0 : port_new();
	if (port)
		h = right_new(p, port, 1);
	ipclock_leave();

	/* told apart, because they are different faults: the machine is
	 * full, or this proc has spent what it was given.
	 */
	if (over)
		return luaL_error(L, "port limit: %d of %d in use",
		    p->nports, p->port_limit);
	if (!port)
		return luaL_error(L, "out of ports");
	if (h < 0)
		return luaL_error(L, "out of rights");

	strncpy(port->tag, tag, sizeof port->tag - 1);
	port->tag[sizeof port->tag - 1] = 0;
	strncpy(port->where, where, sizeof port->where - 1);
	port->where[sizeof port->where - 1] = 0;

	lua_pushinteger(L, h);
	return 1;
}

static int proc_new(const char *code, size_t codelen, const char *chunkname,
    int is_file, int reductions, size_t mem_limit, int port_limit, int priv);
static void proc_launch(struct kproc *p);
static void notify_exit(struct kproc *watcher, int pid, const char *reason,
    int status, const char *exitmsg, int broke, int priv);

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

/* sys.sendright(h) -> a new handle to the same port, send only.
 *
 * Mach's shape: a receive right is the authority to hand out send
 * rights. {__right=h} copies the recv flag, so handing out a port you
 * created would also hand out the ability to receive on it -- and on a
 * port many clients share, any of them could then take another's
 * requests, or take their own and never answer.
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

/* sys.spawn(code_or_fn, opts) -> pid. code_or_fn is source text or a
 * plain lua function, which is dumped to bytecode here and crosses into
 * the child as bytes either way. C functions cannot be dumped, and
 * upvalues beyond _ENV do not carry values across -- the same isolation
 * limit as source text, but easier to trip, since a closure captures an
 * outer local without being asked to.
 */
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
	int port_limit = 0;
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
		lua_getfield(L, 2, "ports");
		if (!lua_isnil(L, -1))
			port_limit = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		/* both budgets are clamped to the parent's below, so a
		 * child is never less contained than whoever spawned it.
		 */
		lua_getfield(L, 2, "name");
		if (!lua_isnil(L, -1))
			snprintf(chunkname, sizeof chunkname, "=%s",
			    luaL_checkstring(L, -1));
		lua_pop(L, 1);
	}

	/* budgets are inherited and may only be asked downward, so a child
	 * is never less contained than its parent. Absent means the
	 * parent's, and a larger request is clamped rather than refused:
	 * refusing would make a supervisor's containment its children's
	 * problem to know about.
	 *
	 * Inherited rather than divided. A cap bounds any one proc, which
	 * makes a runaway loop cost its own proc first; dividing bounds a
	 * tree, and needs an account of who spawned whom.
	 */
	if (reductions <= 0 || reductions > p->reductions)
		reductions = p->reductions;
	if (p->mem_limit && (mem_limit == 0 || mem_limit > p->mem_limit))
		mem_limit = p->mem_limit;
	if (p->port_limit && (port_limit == 0 || port_limit > p->port_limit))
		port_limit = p->port_limit;

	/* opts.arg: one value handed to the child before its chunk runs,
	 * arriving as the chunk's `...`. A message cannot do this job,
	 * because the child's first line is typically require, which runs
	 * before any receive -- so its namespace has to be there already.
	 *
	 * The kernel does not interpret it. It goes through the ordinary
	 * serializer, so rights travel as they do in any message.
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
	    port_limit, PRIV_NONE);
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
		struct minted mt = { .n = 0 };
		int bad;

		/* writing another cpu's running coroutine would race its
		 * stack, and a raise in here would longjmp down that cpu's
		 * resume frame -- leaving this one's ipc bucket held.
		 */
		if (child->status != HATCHING)
			platform_abort("spawn: child ran before its arg");

		/* the parent loses any buffer in the arg here, before the
		 * child can take one: from this line the bytes have one
		 * owner, whether delivery works or not.
		 */
		for (int i = 0; i < argw.bufs.n; i++)
			luabuf_detach(L, argw.bufown[i]);

		ipclock_enter();
		bad = deserialize(child->co, argw.p, argw.len, &off,
		    &argw.bufs, child, 0, &mt);
		ipclock_leave();
		msgbufs_free(&argw.bufs);	/* whatever it did not take */
		if (bad) {
			/* a partial deserialize may have left values on co's
			 * stack under the chunk's feet, and rights already
			 * minted into the child. the proc is unusable; kill
			 * it rather than start it half-built -- which drops
			 * those rights with everything else it held, so
			 * there is nothing for minted_undo to do here.
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

	/* built: the arg is on co's stack and nargs says so. */
	ipclock_enter();
	proc_launch(child);
	ipclock_leave();

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
		notify_exit(p, pid, "noproc", -1, 0, 0, 1);
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
	target->wpriv[target->nwatch] = may_control(p, target) ? 1 : 0;
	target->watchers[target->nwatch++] = p->id;
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.owned(h): the right, as a to-be-closed value.
 *
 *	local guard <close> = sys.owned(sys.newport("srv.session"))
 *
 * Closed when the block ends, by return, break or error, so a port's
 * lifetime is a scope rather than a discipline. __close only, never
 * __gc: a right can travel in a message, and a finalizer runs at
 * whatever moment the collector picks. Here the moment is the point.
 */
static int
owned_close(lua_State *L)
{
	struct kproc *p = self(L);
	int *ud = luaL_checkudata(L, 1, "los.owned");
	struct right *r;

	if (*ud < 0)
		return 0;		/* closed already, or by hand */

	ipclock_enter();
	r = right_get(p, *ud);
	if (r && *ud != 0)
		right_drop(p, r);
	ipclock_leave();

	if (r && *ud != 0 && *ud < p->rhint)
		p->rhint = *ud;
	*ud = -1;
	return 0;
}

static int
api_owned(lua_State *L)
{
	int h = (int)luaL_checkinteger(L, 1);
	int *ud = lua_newuserdatauv(L, sizeof *ud, 0);

	*ud = h;
	if (luaL_newmetatable(L, "los.owned")) {
		lua_pushcfunction(L, owned_close);
		lua_setfield(L, -2, "__close");
	}
	lua_setmetatable(L, -2);
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
		right_drop(p, r);
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
	/* the pooled part of mem_used, so a proc holding buffers can be
	 * told from one holding lua objects. */
	lua_pushinteger(L, (lua_Integer)p->buf_used);
	return 4;
}

static size_t
heap_release_all(void)
{
	size_t freed = 0;

	if (shared_heap)
		return luaheap_release(shared_heap);
	for (int i = 0; i < prochigh; i++)
		if (procv[i] && procv[i]->heap)
			freed += luaheap_release(procv[i]->heap);
	return freed;
}

/* sys.reclaim() -> bytes. Hand back what the lua heap holds and is not
 * using: whole chunks nothing sits in, and the large-block cache.
 * Ungated, like sys.stats: it frees memory and reveals nothing.
 */
static int
api_reclaim(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)heap_release_all());
	return 1;
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
	unsigned long long tfull = 0, tdead = 0;

	for (unsigned i = 0; cpu_at(i); i++) {
		tidle += cpu_at(i)->nidle;
		tlaps += cpu_at(i)->nlaps;
		tdisp += cpu_at(i)->ndispatch;
		tfull += cpu_at(i)->ndrop_full;
		tdead += cpu_at(i)->ndrop_dead;
	}
	lua_pushinteger(L, (lua_Integer)tidle);
	lua_setfield(L, -2, "idles");
	lua_pushinteger(L, rights_high);
	lua_setfield(L, -2, "rightshigh");
	lua_pushinteger(L, (lua_Integer)tlaps);
	lua_setfield(L, -2, "laps");
	lua_pushinteger(L, (lua_Integer)tdisp);
	lua_setfield(L, -2, "dispatches");
	lua_pushinteger(L, (lua_Integer)tfull);
	lua_setfield(L, -2, "dropfull");
	lua_pushinteger(L, (lua_Integer)tdead);
	lua_setfield(L, -2, "dropdead");


	/* the firmware's view: what the machine has, and what is left. this
	 * is the ceiling the other figures sit under, since a proc is a
	 * lua_State drawn from the same pool.
	 */
	unsigned long long mtotal = 0, mavail = 0, mlargest = 0;

	platform_meminfo(&mtotal, &mavail, &mlargest);
	lua_pushinteger(L, (lua_Integer)mtotal);
	lua_setfield(L, -2, "memtotal");
	lua_pushinteger(L, (lua_Integer)mavail);
	lua_setfield(L, -2, "memavail");
	/* the largest run of memavail. A heap fragmented below what a
	 * chunk costs refuses one while memavail still looks healthy.
	 */
	lua_pushinteger(L, (lua_Integer)mlargest);
	lua_setfield(L, -2, "memlargest");

	/* and the pool the lua heaps are carved from, which on a board
	 * with PSRAM is a different one. What bounds how many procs can
	 * exist is this, not the figures above: a machine can be out of
	 * room for another heap with plenty of sram left.
	 */
	unsigned long long ctotal = 0, cavail = 0, clargest = 0;

	platform_chunkinfo(&ctotal, &cavail, &clargest);
	lua_pushinteger(L, (lua_Integer)ctotal);
	lua_setfield(L, -2, "chunktotal");
	lua_pushinteger(L, (lua_Integer)cavail);
	lua_setfield(L, -2, "chunkavail");
	lua_pushinteger(L, (lua_Integer)clargest);
	lua_setfield(L, -2, "chunklargest");

	/* the c heap, i.e. everything not on a per-proc lua heap: port
	 * messages, net tokens and payload copies, loadfile buffers.
	 * sys.meminfo(pid) covers the lua side.
	 */
	/* zeroed, so a platform that cannot answer reports nothing rather
	 * than the stack.
	 */
	size_t hlive = 0, hpeak = 0;
	unsigned long hblocks = 0, htotal = 0;

	kheap_stats(&hlive, &hpeak, &hblocks, &htotal);
	lua_pushinteger(L, (lua_Integer)hlive);
	lua_setfield(L, -2, "heap_used");
	lua_pushinteger(L, (lua_Integer)hpeak);
	lua_setfield(L, -2, "heap_peak");
	lua_pushinteger(L, (lua_Integer)hblocks);
	lua_setfield(L, -2, "heap_blocks");
	lua_pushinteger(L, (lua_Integer)htotal);
	lua_setfield(L, -2, "heap_total_allocs");
	/* los.buf's storage, which comes from the chunk source rather than
	 * a lua heap. Counted in heap_used like every other chunk, and
	 * here on its own so it can be told apart. */
	lua_pushinteger(L, (lua_Integer)kbuf_pooled());
	lua_setfield(L, -2, "buf_used");
	/* buffers made since boot, beside the bytes held now: a rate says
	 * whether a path allocates per operation, which a level cannot.
	 */
	lua_pushinteger(L, (lua_Integer)luabuf_allocs());
	lua_setfield(L, -2, "buf_allocs");

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
			hs.cached += one.cached;
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
	/* how much of unused sys.reclaim would return, so "held" can be
	 * told from "fragmented" without guessing.
	 */
	lua_pushinteger(L, (lua_Integer)hs.cached);
	lua_setfield(L, -2, "lua_cached");
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
		lua_pushinteger(L, (lua_Integer)claim_won);
		lua_setfield(L, -2, "claimwon");
		lua_pushinteger(L, (lua_Integer)claim_lost);
		lua_setfield(L, -2, "claimlost");
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
		lua_pushstring(L, port->tag);
		lua_setfield(L, -2, "tag");
		lua_pushstring(L, port->where);
		lua_setfield(L, -2, "where");
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

/* sys.wchan(pid): what a blocked proc is waiting on, as unix reports a
 * wchan. A port is named by its index -- the number the wire already
 * carries: not friendly, but stable and unique. Other states report
 * themselves, and "alt[...]" lists every port an alt waits across.
 */
/* pushes the wchan string for p, so api_wchan and api_pidstat report the
 * same thing by construction rather than by two copies agreeing.
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
	case HATCHING:
		lua_pushliteral(L, "hatching");
		return 1;
	case BROKE:
		lua_pushliteral(L, "broke");
		return 1;
	case STOPPED:
		lua_pushliteral(L, "stopped");
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
 * The target can be running, pushing and popping frames, while a reader
 * walks it. A spinning proc is the one worth sampling, so it is held
 * still rather than refused. Freeze first, then wait: raising frozen
 * stops dispatch from resuming it, and waiting for it to stop being
 * some cpu's `current` makes the stack quiet. The other order lets it
 * be re-dispatched between the check and the walk. The wait yields
 * rather than spins, so two readers cannot deadlock.
 */

/* Ask the proc, not the cpus. A scan over platform_ncpu() misses an AP
 * that is already dispatching but not yet counted; p->oncpu is written
 * by whichever cpu has p in hand, counted or not. p->home says where it
 * last ran, which is a report rather than an answer.
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
 * The yield cannot be shared: lua_yieldk names a continuation, and each
 * syscall's is its own. So this reports the caller's situation and lets
 * it yield by name -- HOLD_WAIT yields to its own continuation,
 * HOLD_GONE raises, HOLD_SELF acts with nothing to hold, and HOLD_HELD
 * acts and then thaws.
 */

/* A body that can raise must run protected: a raise past the thaw
 * leaves the target frozen, and a proc that never runs again is worse
 * than the race. Anything building a table in the caller's state can
 * raise, because it allocates against that caller's memory limit.
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
 * A traceback of another proc, held still first. Two rules keep it safe.
 * Nothing is pushed onto the target's stack: the "Sln" info string is
 * push-free, unlike "f" or "L", and an unbalanced target resumes into
 * garbage. And no lua runs in the target -- a traceback would allocate
 * against its mem_limit, and stringifying a value could call __tostring
 * in a proc that is supposed to be still. So this reports structure
 * only. Ambient, like sys.procs and sys.wchan.
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

	/* every coroutine, not just p->co: a proc built on lib/thread
	 * keeps its threads as coroutines, and walking p->co alone reports
	 * the scheduler -- the same frames idle or deadlocked.
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
 * The expensive one: a line hook fires per line rather than per
 * instruction budget, costing a traced proc several times its untraced
 * runtime. It buys a record of how a proc reached its fault, which a
 * stack cannot give -- a traceback collapses the recursion that led
 * there into one tail-call marker. An untraced proc pays nothing: the
 * mask carries the line bit only while a ring exists.
 */

/* sys.set_torture(pid, on) -- yield between every instruction. Costs
 * the machine a real guarantee while it is on, so PRIV_BOOT only.
 *
 * Arming is by inheritance as much as by the sweep: lua_newthread
 * copies hook, mask and count from its creator, so a thread made after
 * this returns is born tortured. Turn it on before spawning the threads
 * that are meant to be cut.
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
		/* the one call here that writes to another proc, so the
		 * one that takes a right to it. Reading does not: arming
		 * is what slows the target down, and what reallocates a
		 * ring its own hook is filling.
		 */
		if (p != self(L) && !may_control(self(L), p))
			return luaL_error(L, "no right to proc %d", p->id);
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

	/* held for the arm itself, and only for that: trace_arm frees a
	 * ring the target's line hook is writing into. Everything above
	 * that can raise has already run, so the freeze spans nothing that
	 * could jump past the thaw.
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
 * Aggregated here rather than in the caller, because handing over a
 * whole ring charges the reader's mem_limit for the act of reading.
 * Keyed on source and line, not on thread: what a line costs is a
 * property of the line, and keying on both multiplies the rows of a
 * threaded proc. Sorted by cpu, so the answer to "where does the time
 * go" is the top of the list.
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

	/* Sized to the ring, so every distinct line gets a row. A fixed
	 * table cannot: aggregation meets keys in the order they occur, so
	 * one that fills stops admitting new lines -- and the ones it then
	 * fails to report are whichever appeared late, not the cold ones.
	 * A histogram that quietly does that looks like an answer.
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
	 * Anything cleverer would be optimizing the reader.
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

/* No static fallback table when that malloc fails: sys.tracehist is an
 * ordinary syscall, so two procs on two cpus can be inside it at once,
 * both writing one shared array. Raising rather than locking, because
 * the lock would have to span the table building below, which allocates
 * in the caller's state and can raise straight through the unlock.
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

/* los.dbg: stop another proc, read it, resume it. Its own module, so
 * sys.syscalls() does not count these. Design: docs/debugging.md.
 */
static void proc_rearm(struct kproc *p);
static void proc_armall(struct kproc *p, int count);
static void make_ready(struct kproc *p);

static int
may_debug(struct kproc *p, struct kproc *target)
{
	return may_control(p, target) || proc_has_port(p, dbgport);
}

/* the notice port, or 0 if gone. The pair is checked rather than a
 * pointer chased, as proc_selfport does.
 */
static struct kport *
dbg_port(struct kdbg *d)
{
	if (!d || !d->portgen)
		return 0;

	struct kport *port = portv[d->portidx];

	if (!port || port->gen != d->portgen)
		return 0;
	return port;
}

/* a port nobody can receive on is a debugger that reads no more */
static int
dbg_orphaned(struct kdbg *d)
{
	struct kport *port = dbg_port(d);

	if (!port || port->dead)
		return 1;
	return atomic_load_explicit(&port->nrecv, memory_order_relaxed) == 0;
}

/* All of it under the wide lock, which is what dbg_sweep reads p->dbg
 * inside: clearing and freeing anywhere else is a use-after-free on the
 * cpu walking the table. Callers hold nothing, or hold it already.
 */
static void
dbg_free(struct kproc *p)
{
	struct kdbg *d;
	struct kport *port;

	ipclock_enter();
	d = p->dbg;
	p->dbg = 0;
	port = d ? dbg_port(d) : 0;
	free(d);
	if (port)
		port_unref(port);
	ipclock_leave();
}


/* Where in p->coros a state sits, 1-based: the coroutine ABI los.dbg
 * takes and reports. Not sys.stack's ordering -- p->L is not on this
 * list. Read only while the proc is held.
 */
static int
dbg_coidx(struct kproc *p, lua_State *co)
{
	struct kextra *kx;
	int i = 1;

	if (!co)
		return 0;
	TAILQ_FOREACH(kx, &p->coros, link) {
		if (kx_state(kx) == co)
			return i;
		i++;
	}
	return 0;
}


/* Tell the debugger its target stopped. port_push wants the wide lock,
 * so callers hold it already or hold nothing.
 */
static void
dbg_notify(struct kproc *p, int reason, int exited)
{
	struct kdbg *d = p->dbg;

	if (!d)
		return;

	struct kport *port = dbg_port(d);

	if (!port)
		return;

	struct wbuf w = { 0 };
	unsigned int npairs = exited ? 3 : 6;
	lua_Integer pid = p->id;
	lua_Integer line = d->stopline;
	lua_Integer co = dbg_coidx(p, d->stopco);
	const char *reasonstr = dbg_reasonstr(reason);
	const char *file = d->stopfile >= 0 ? d->file[d->stopfile] : "";
	unsigned int klen;

	if (wbyte(&w, 'B') || wput(&w, &npairs, 4))
		goto fail;

	klen = 3;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "dbg", 3) ||
	    wbyte(&w, 'I') || wput(&w, &pid, sizeof pid))
		goto fail;

	klen = 4;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "stop", 4))
		goto fail;
	klen = (unsigned int)strlen(reasonstr);
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, reasonstr, klen))
		goto fail;

	klen = 4;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "exit", 4) ||
	    wbyte(&w, exited ? 'T' : 'F'))
		goto fail;

	if (!exited) {
		klen = 4;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "line", 4) ||
		    wbyte(&w, 'I') || wput(&w, &line, sizeof line))
			goto fail;

		klen = 2;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "co", 2) ||
		    wbyte(&w, 'I') || wput(&w, &co, sizeof co))
			goto fail;

		klen = 4;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "file", 4))
			goto fail;
		klen = (unsigned int)strlen(file);
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, file, klen))
			goto fail;
	}

	/* npairs was written before the pairs, so a message that got this
	 * far has exactly the count it claims.
	 */
	if (port_push_owned(port, w.p, w.len, 0, 0, 0, 0))
		free(w.p);
	return;
fail:
	free(w.p);
}


/* the kernel boundary: p->co has just yielded, and this cpu owns p.
 * Returns whether the proc is now stopped and must not be resumed.
 */
static int
dbg_commit(struct kproc *p)
{
	struct kdbg *d = p->dbg;

	if (!d)
		return 0;

	int reason = atomic_exchange_explicit(&d->pending, DBG_RUN,
	    memory_order_relaxed);

	if (reason == DBG_RUN)
		return 0;

	lock(&schedlock);
	p->status = STOPPED;
	unlock(&schedlock);
	/* dbg_sweep sends it: a notice needs the ipc lock and this is not
	 * the place to take it.
	 */
	atomic_store_explicit(&d->notify, reason, memory_order_relaxed);
	return 1;
}

/* The debugger has gone. Marks only: disarming the target's hooks from
 * here would race a target running on another cpu, so dbg_settle does
 * it. Waking a parked one is what gets it to a cpu at all.
 */
static void
dbg_mark_orphan(struct kproc *p)
{
	struct kdbg *d = p->dbg;

	if (!d || !dbg_orphaned(d))
		return;
	atomic_store_explicit(&d->detach, 1, memory_order_relaxed);

	/* tested and set under one hold, and re-asked every sweep: a proc
	 * that commits a stop in between would be marked and never woken,
	 * which is the stranding this exists to prevent.
	 */
	int wake;

	lock(&schedlock);
	wake = p->status == STOPPED;
	if (wake)
		p->status = READY;
	unlock(&schedlock);
	if (wake)
		make_ready(p);	/* the caller holds the bucket it wants */
}

/* make a stopped proc runnable again. The caller has thawed already:
 * make_ready takes schedlock, and so does proc_thaw.
 */
static void
dbg_resume(struct kproc *p)
{
	ipclock_enter();
	lock(&schedlock);
	p->status = READY;
	unlock(&schedlock);
	make_ready(p);
	ipclock_leave();
}

/* run_proc, on the cpu that owns this proc and before it is resumed:
 * the one place a debugger's state can be torn down safely, because
 * only here is it certain the target is running nowhere.
 */
static void
dbg_settle(struct kproc *p)
{
	if (!p->dbg ||
	    !atomic_load_explicit(&p->dbg->detach, memory_order_relaxed))
		return;
	dbg_free(p);
	proc_rearm(p);		/* the mask loses LUA_MASKLINE with it */
}

/* Once per lap, holding nothing. Every cpu runs laps, so both halves
 * are claimed with an exchange; the wide lock is what port_push wants
 * and what serializes the walk against another cpu's proc_new.
 */
static void
dbg_sweep(void)
{
	for (int i = 0; i < prochigh; i++) {
		struct kproc *p = procv[i];

		/* unlocked, and it has to be: this runs on every lap of
		 * every cpu, and taking the wide lock to find nothing is
		 * the cost the ordinary machine would pay.
		 */
		if (!p || !p->dbg)
			continue;

		ipclock_enter();
		if (p->dbg) {
			int reason = atomic_exchange_explicit(
			    &p->dbg->notify, DBG_RUN, memory_order_relaxed);

			if (reason != DBG_RUN)
				dbg_notify(p, reason, 0);
			dbg_mark_orphan(p);
		}
		ipclock_leave();
	}
}

/* dbg.attach(pid, noticeright). The right must be receivable: a notice
 * nobody reads is how a target gets stranded. One debugger per proc.
 */
static int api_dbg_attach_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_attach(lua_State *L)
{
	return api_dbg_attach_k(L, LUA_OK, 0);
}

static int
api_dbg_attach_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *me = self(L);
	struct kproc *p;
	struct right *r = right_get(me, luaL_checkinteger(L, 2));

	(void)status;
	if (!r)
		return luaL_error(L, "bad right");

	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_attach_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	/* every failure below thaws before it raises: a raise past the
	 * thaw leaves the target frozen for good, which is worse than
	 * whatever was being refused.
	 */
	const char *err = 0;

	if (!may_debug(me, p))
		err = "no right to debug that proc";
	else if (p->dbg)
		err = "already attached";
	else if (p->torture)
		/* torture skips the walk-out for a nested state, so a stop
		 * requested there can never be committed. See preempt_hook.
		 */
		err = "proc is under sys.set_torture";
	else if (p->status == DEAD)
		err = "proc is dead";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = malloc(sizeof *d);

	if (!d) {
		proc_thaw(p);
		return luaL_error(L, "out of memory");
	}
	dbg_init(d, me->id);
	d->portidx = r->port->idx;
	d->portgen = r->port->gen;

	int orphan;

	/* the kernel's own reference, so the kport cannot be recycled
	 * under the (idx, gen) pair. Taken wide because dbg_free's
	 * matching unref is wide.
	 */
	ipclock_enter();
	orphan = atomic_load_explicit(&r->port->nrecv,
	    memory_order_relaxed) == 0 || r->port->dead;
	if (!orphan)
		r->port->nrights++;
	ipclock_leave();

	if (orphan) {
		free(d);
		proc_thaw(p);
		return luaL_error(L, "that right cannot be received on");
	}
	p->dbg = d;
	proc_thaw(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* dbg.detach(pid): let the target go, running. */
static int api_dbg_detach_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_detach(lua_State *L)
{
	return api_dbg_detach_k(L, LUA_OK, 0);
}

static int
api_dbg_detach_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_detach_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), p)) {
		proc_thaw(p);
		return luaL_error(L, "no right to debug proc %d", p->id);
	}

	int wake = p->dbg && p->status == STOPPED;

	dbg_free(p);
	proc_rearm(p);
	proc_thaw(p);
	/* thawed first: make_ready wants the ipc lock and schedlock, and
	 * proc_thaw takes schedlock of its own.
	 */
	if (wake)
		dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* dbg.status(pid): ambient, because it reports structure only. */
static int api_dbg_status_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_status(lua_State *L)
{
	return api_dbg_status_k(L, LUA_OK, 0);
}

static void
dbg_push_status(lua_State *L, struct kproc *p)
{
	struct kdbg *d = p->dbg;

	lua_createtable(L, 0, 9);
	lua_pushboolean(L, d != 0);
	lua_setfield(L, -2, "attached");
	lua_pushboolean(L, p->status == STOPPED);
	lua_setfield(L, -2, "stopped");
	lua_pushboolean(L, p->status == BROKE);
	lua_setfield(L, -2, "broke");
	if (!d)
		return;
	lua_pushinteger(L, d->dbgpid);
	lua_setfield(L, -2, "debugger");
	lua_pushstring(L, dbg_reasonstr(d->reason));
	lua_setfield(L, -2, "reason");
	lua_pushinteger(L, d->nbp);
	lua_setfield(L, -2, "nbreak");
	if (p->status != STOPPED)
		return;
	lua_pushinteger(L, d->stopline);
	lua_setfield(L, -2, "line");
	lua_pushinteger(L, dbg_coidx(p, d->stopco));
	lua_setfield(L, -2, "co");
	if (d->stopfile >= 0) {
		lua_pushstring(L, d->file[d->stopfile]);
		lua_setfield(L, -2, "file");
	}
	if (d->stopbp) {
		lua_pushinteger(L, d->stopbp);
		lua_setfield(L, -2, "bp");
	}
}

static int
dbg_status_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);

	dbg_push_status(L, p);
	return 1;
}

static int
api_dbg_status_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_status_k);
	case HOLD_SELF:
		dbg_push_status(L, p);
		return 1;
	}

	/* protected: the table is built in this proc's state, so it
	 * allocates, so it can raise -- and a raise past the thaw would
	 * leave the target frozen for good.
	 */
	lua_pushcfunction(L, dbg_status_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* the target of an acting call, held and checked. Every caller thaws
 * before it raises: a raise past the thaw leaves the target frozen for
 * good, which is a worse bug than whatever was being refused.
 */
static const char *
dbg_acting(lua_State *L, struct kproc *p)
{
	if (!may_debug(self(L), p))
		return "no right to debug that proc";
	if (!p->dbg)
		return "not attached";
	return 0;
}

/* dbg.stop(pid): stop at the next line. Three cases below, and what
 * separates them is whether any of the target is executing.
 */
static int api_dbg_stop_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_stop(lua_State *L)
{
	return api_dbg_stop_k(L, LUA_OK, 0);
}

static int
api_dbg_stop_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_stop_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke";
	if (!err && p->status == DEAD)
		err = "proc is dead";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;

	if (p->status == STOPPED) {
		proc_thaw(p);
		lua_pushboolean(L, 1);
		return 1;
	}

	if (p->status == BLOCKED) {
		/* nothing to interrupt: park it here. Waiters stay linked
		 * and messages stay queued; the block continuation
		 * re-polls on continue.
		 */
		d->stopco = p->co;
		d->stopline = 0;
		d->stopfile = -1;
		d->reason = DBG_REQ;
		d->stopbp = 0;
		atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
		lock(&schedlock);
		p->status = STOPPED;
		unlock(&schedlock);
		atomic_store_explicit(&d->notify, DBG_REQ,
		    memory_order_relaxed);
		proc_thaw(p);
		lua_pushboolean(L, 1);
		return 1;
	}

	atomic_store_explicit(&d->stopreq, DBG_REQ, memory_order_relaxed);
	/* every coroutine, because the hook must fire wherever the proc
	 * is; hookforced = 2 is what puts the counts back afterwards.
	 * Legal only because proc_hold says no cpu is running the target.
	 */
	proc_armall(p, 1);
	p->hookforced = 2;
	proc_thaw(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* dbg.cont(pid). The resume is the preemption path unchanged: the
 * innermost state picks up after the instruction it stopped on.
 */
static int api_dbg_cont_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_cont(lua_State *L)
{
	return api_dbg_cont_k(L, LUA_OK, 0);
}

static int
api_dbg_cont_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_cont_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke: a corpse can be read, not resumed";
	if (!err && p->status != STOPPED)
		err = "proc is not stopped";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;

	d->step = STEP_NONE;
	d->stepco = 0;
	d->reason = DBG_RUN;
	d->stopco = 0;
	atomic_store_explicit(&d->pending, DBG_RUN, memory_order_relaxed);
	atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
	proc_rearm(p);		/* the mask may lose LUA_MASKLINE here */
	proc_thaw(p);
	dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* dbg.step(pid, "in"|"over"|"out"). "in" stops at the next line
 * anywhere in the proc; the others stay in the stopped coroutine and
 * degrade to "in" if it has since died.
 */
static int api_dbg_step_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_step(lua_State *L)
{
	return api_dbg_step_k(L, LUA_OK, 0);
}

static int
api_dbg_step_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	const char *how = luaL_optstring(L, 2, "in");

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_step_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke: a corpse can be read, not resumed";
	if (!err && p->status != STOPPED)
		err = "proc is not stopped";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;
	int over = strcmp(how, "in") != 0;
	int alive = d->stopco && lua_status(d->stopco) == LUA_YIELD;

	if (over && alive) {
		d->step = STEP_OVER;
		d->stepco = d->stopco;
		d->stepdepth = dbg_depth(d->stopco);
		if (!strcmp(how, "out"))
			d->stepdepth--;
	} else {
		d->step = STEP_IN;
		d->stepco = 0;
	}
	d->reason = DBG_RUN;
	d->stopco = 0;
	atomic_store_explicit(&d->pending, DBG_RUN, memory_order_relaxed);
	atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
	proc_rearm(p);		/* the mask gains LUA_MASKLINE for the step */
	proc_thaw(p);
	dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* dbg.setbreak(pid, file, line) -> id. The file is matched against
 * short_src, which is what a stop and a traceback both report.
 */
static int api_dbg_setbreak_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_setbreak(lua_State *L)
{
	return api_dbg_setbreak_k(L, LUA_OK, 0);
}

static int
api_dbg_setbreak_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	const char *file = luaL_checkstring(L, 2);
	lua_Integer line = luaL_checkinteger(L, 3);

	(void)status;
	if (line <= 0)
		return luaL_error(L, "a breakpoint needs a line");

	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_setbreak_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);
	struct kdbg *d = p->dbg;

	if (!err && d->nbp >= DBGBP)
		err = "too many breakpoints";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	/* interning here rather than at the hit: a file the table has no
	 * room for is a breakpoint that would never match, and saying so
	 * now is better than never firing.
	 */
	int fileid = dbg_intern(d, 0, file);

	if (fileid < 0) {
		proc_thaw(p);
		return luaL_error(L, "too many source files");
	}

	struct kbp *b = &d->bp[d->nbp++];

	b->fileid = fileid;
	b->line = (int)line;
	b->enabled = 1;
	b->hits = 0;
	b->id = d->nextid++;
	dbg_remask(d);
	proc_rearm(p);		/* the mask gains LUA_MASKLINE with the first */
	proc_thaw(p);
	lua_pushinteger(L, b->id);
	return 1;
}

/* dbg.clearbreak(pid, id): id of 0 clears every one. */
static int api_dbg_clearbreak_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_clearbreak(lua_State *L)
{
	return api_dbg_clearbreak_k(L, LUA_OK, 0);
}

static int
api_dbg_clearbreak_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	lua_Integer id = luaL_optinteger(L, 2, 0);

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_clearbreak_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;
	int found = 0;

	for (int i = 0; i < d->nbp; i++) {
		if (id && d->bp[i].id != id)
			continue;
		found++;
		d->bp[i] = d->bp[--d->nbp];
		if (id)
			break;
		i--;
	}
	dbg_remask(d);
	proc_rearm(p);		/* the last one out takes LUA_MASKLINE */
	proc_thaw(p);
	lua_pushboolean(L, found != 0);
	return 1;
}

/* dbg.breaks(pid): ambient, being structure. */
static int api_dbg_breaks_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_breaks(lua_State *L)
{
	return api_dbg_breaks_k(L, LUA_OK, 0);
}

static int
dbg_breaks_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct kdbg *d = p->dbg;

	lua_createtable(L, d ? d->nbp : 0, 0);
	for (int i = 0; d && i < d->nbp; i++) {
		lua_createtable(L, 0, 5);
		lua_pushinteger(L, d->bp[i].id);
		lua_setfield(L, -2, "id");
		lua_pushstring(L, d->file[d->bp[i].fileid]);
		lua_setfield(L, -2, "file");
		lua_pushinteger(L, d->bp[i].line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, d->bp[i].hits);
		lua_setfield(L, -2, "hits");
		lua_pushboolean(L, d->bp[i].enabled);
		lua_setfield(L, -2, "enabled");
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

static int
api_dbg_breaks_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_breaks_k);
	case HOLD_SELF:
		return dbg_breaks_body(L);
	}

	lua_pushcfunction(L, dbg_breaks_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* The readers, all one shape: hold the target, run a body from
 * src/dbg.c under pcall, restore the target's top, thaw.
 */
struct dbgread {
	struct kproc *p;
	int co, level, root, npath;
	const char *name;
	size_t nlen;
	struct dbgkey path[DBGPATH];
};

/* the co'th coroutine of a proc, or 0. Held, so the list cannot move. */
static lua_State *
dbg_costate(struct kproc *p, int co)
{
	struct kextra *kx;
	int i = 1;

	TAILQ_FOREACH(kx, &p->coros, link) {
		if (i++ == co)
			return kx_state(kx);
	}
	return 0;
}

static int
dbg_read_body(lua_State *L)
{
	struct dbgread *a = lua_touserdata(L, 1);
	lua_State *co = dbg_costate(a->p, a->co);

	if (!co)
		return luaL_error(L, "no such coroutine");
	switch (a->root) {
	case -1:
		dbg_push_frames(L, co);
		return 1;
	case -2:
		dbg_push_locals(L, co, a->level);
		return 1;
	case -3:
		dbg_push_upvals(L, co, a->level);
		return 1;
	}
	if (!dbg_push_path(L, co, a->level, a->root, a->name, a->nlen,
	    a->path, a->npath))
		return 0;
	return 1;
}

/* the shared tail: the target's top is recorded OUTSIDE the pcall and
 * restored on every path, because the body pushes onto the target and
 * building the result can raise in the caller.
 */
static int
dbg_read(lua_State *L, struct dbgread *a)
{
	lua_State *co = dbg_costate(a->p, a->co);
	int top = co ? lua_gettop(co) : 0;

	lua_pushcfunction(L, dbg_read_body);
	lua_pushlightuserdata(L, a);

	int rc = lua_pcall(L, 1, 1, 0);

	if (co)
		lua_settop(co, top);
	proc_thaw(a->p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* frames and coros are structure, so ambient like sys.stack; locals,
 * upvalues and get are the target's data and take the right.
 */
static int api_dbg_frames_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_frames(lua_State *L)
{
	return api_dbg_frames_k(L, LUA_OK, 0);
}

static int
api_dbg_frames_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.root = -1;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_frames_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot read its own frames here");
	}
	return dbg_read(L, &a);
}

static int api_dbg_coros_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_coros(lua_State *L)
{
	return api_dbg_coros_k(L, LUA_OK, 0);
}

static int
dbg_coros_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct kdbg *d = p->dbg;
	struct kextra *kx;
	int i = 0;

	lua_newtable(L);
	TAILQ_FOREACH(kx, &p->coros, link) {
		lua_State *co = kx_state(kx);

		lua_createtable(L, 0, 4);
		lua_pushinteger(L, ++i);
		lua_setfield(L, -2, "i");
		lua_pushstring(L, co == p->co ? "main" : "coroutine");
		lua_setfield(L, -2, "label");
		lua_pushinteger(L, lua_status(co));
		lua_setfield(L, -2, "status");
		if (d && d->stopco == co) {
			lua_pushboolean(L, 1);
			lua_setfield(L, -2, "stopped");
		}
		lua_rawseti(L, -2, i);
	}
	return 1;
}

static int
api_dbg_coros_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_coros_k);
	case HOLD_SELF:
		return dbg_coros_body(L);
	}

	lua_pushcfunction(L, dbg_coros_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int api_dbg_locals_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_locals(lua_State *L)
{
	return api_dbg_locals_k(L, LUA_OK, 0);
}

static int
api_dbg_locals_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	a.root = -2;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_locals_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}

static int api_dbg_upvalues_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_upvalues(lua_State *L)
{
	return api_dbg_upvalues_k(L, LUA_OK, 0);
}

static int
api_dbg_upvalues_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	a.root = -3;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_upvalues_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}

/* dbg.get(pid, co, level, root, name, path): one value, by literal key
 * path. The path is keys, never an expression: nothing here can call.
 */
static int api_dbg_get_k(lua_State *L, int status, lua_KContext ctx);

static int
api_dbg_get(lua_State *L)
{
	return api_dbg_get_k(L, LUA_OK, 0);
}

static int
api_dbg_get_k(lua_State *L, int status, lua_KContext ctx)
{
	/* rebuilt from the arguments on every re-entry, which is why a
	 * local is right: they are still on the stack, and a static would
	 * be shared with every other cpu.
	 */
	struct dbgread a = { 0 };
	const char *root = luaL_checkstring(L, 4);

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	if (!strcmp(root, "local"))
		a.root = DBGROOT_LOCAL;
	else if (!strcmp(root, "upvalue"))
		a.root = DBGROOT_UPVAL;
	else if (!strcmp(root, "global"))
		a.root = DBGROOT_GLOBAL;
	else
		return luaL_error(L, "root is local, upvalue or global");
	a.name = luaL_checklstring(L, 5, &a.nlen);

	if (!lua_isnoneornil(L, 6)) {
		luaL_checktype(L, 6, LUA_TTABLE);
		lua_Integer n = luaL_len(L, 6);

		if (n > DBGPATH)
			return luaL_error(L, "path too deep");
		for (lua_Integer i = 1; i <= n; i++) {
			struct dbgkey *k = &a.path[a.npath++];

			lua_rawgeti(L, 6, i);
			if (lua_type(L, -1) == LUA_TNUMBER) {
				k->kind = DBGKEY_INT;
				k->i = lua_tointeger(L, -1);
			} else if (lua_type(L, -1) == LUA_TSTRING) {
				k->kind = DBGKEY_STR;
				k->s = lua_tolstring(L, -1, &k->slen);
			} else {
				return luaL_error(L,
				    "a path key is a string or a number");
			}
			lua_pop(L, 1);
		}
	}

	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_get_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}

static const luaL_Reg kdbgapi[] = {
	{ "attach", api_dbg_attach },
	{ "detach", api_dbg_detach },
	{ "status", api_dbg_status },
	{ "stop", api_dbg_stop },
	{ "cont", api_dbg_cont },
	{ "step", api_dbg_step },
	{ "setbreak", api_dbg_setbreak },
	{ "clearbreak", api_dbg_clearbreak },
	{ "breaks", api_dbg_breaks },
	{ "frames", api_dbg_frames },
	{ "coros", api_dbg_coros },
	{ "locals", api_dbg_locals },
	{ "upvalues", api_dbg_upvalues },
	{ "get", api_dbg_get },
	{ 0, 0 }
};

int
luaopen_los_dbg(lua_State *L)
{
	luaL_newlib(L, kdbgapi);
	return 1;
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
 * takes the same right as sys.kill. what it destroys is already dead,
 * but it is not nothing: a corpse carries the line trace and the stack
 * that explain the death, and the supervisor about to read them is the
 * one proc that must not have it pulled out from under it.
 */
static int
api_reap(lua_State *L)
{
	struct kproc *p = find_proc((int)luaL_checkinteger(L, 1));

	if (!p)
		return luaL_error(L, "no such proc");
	if (!may_control(self(L), p))
		return luaL_error(L, "no right to proc %d", p->id);
	if (p->status != BROKE)
		return luaL_error(L, "proc %d is not broke", p->id);
	proc_reap(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.kill(pid): stop a proc that will not stop on its own. The
 * cooperative path is the hangup cascade, and this is the backstop for
 * a loop that never parks. The target becomes a corpse exactly as a
 * crash makes one, held BROKE for inspection and reaping. Killing self
 * is refused: freeing the caller mid-syscall is not smuggled in here.
 *
 * The authority is a right to the target's self port, which sys.spawn
 * returns to the parent: a supervisor may stop what it started, and a
 * proc that learned a pid from sys.procs may not stop a stranger.
 */
static int
api_kill(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc(pid);

	if (target == p)
		return luaL_error(L, "cannot kill self");
	if (target && !may_control(p, target))
		return luaL_error(L, "no right to proc %d", pid);
	if (!target || target->status == BROKE || target->status == DEAD) {
		lua_pushboolean(L, 0);	/* nothing to kill: already gone */
		return 1;
	}
	proc_break(target, "killed");
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.set_priority(pid, weight): a policy knob, not the scheduler. It
 * writes a clamped integer that the dispatch loop reads every lap, so
 * no lua runs inside a scheduling decision and a crashing policy proc
 * cannot wedge dispatch -- the reason sched_ext bounds its programs
 * rather than letting them be the dispatcher. Weight 1 is plain
 * round-robin; higher weight is resumed up to `weight` times per lap.
 *
 * Gated on the scheduling capability, or any child could hand itself
 * the largest weight and starve every other proc.
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

/* sys.priority(pid) -> weight, pri, cpu. weight is the gated knob, pri
 * what the feedback computes from it, cpu per-mille of wall time
 * decayed. Reading is not gated: the same class of information
 * sys.procs and sys.meminfo hand out already.
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
 * and one call, so rendering a row costs one kernel entry and adding a
 * column costs no new entry point. The single-value accessors stay,
 * because tests and /proc read them, and share push_wchan with this.
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
	/* instructions between preempt hooks. Reported because it is a
	 * containment bound like mem below it, inherited from the parent
	 * the same way, and otherwise invisible -- there was no way to ask
	 * a proc what budget it was actually given.
	 */
	lua_pushinteger(L, p->reductions);
	lua_setfield(L, -2, "reductions");
	/* ports held and the cap on them, the third inherited budget */
	lua_pushinteger(L, p->nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, p->nports_peak);
	lua_setfield(L, -2, "portspeak");
	lua_pushinteger(L, p->port_limit);
	lua_setfield(L, -2, "portlimit");
	/* raw cycles this proc has spent running, which the scheduler
	 * accumulates for its own decay. It answers what a line trace
	 * cannot: the kernel's own work -- dispatch, push and pop,
	 * serializing -- appears in no proc's trace. Two reads around a
	 * piece of work attribute it across procs with nothing added to a
	 * hot path, and what the wall clock has that the sum does not is
	 * the kernel's.
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

	/* capped like sys.newport: a timer is a port, and a loop asking
	 * for timers spends the table just as fast.
	 */
	struct kport *port = port_budget_left(p) ? port_new() : 0;

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

/* sys.hungup(h): is this proc the only holder of the port behind h?
 * That is our eof, and the formulation matters. Plan 9's pipes count
 * opens of each end, which they can because a Chan is explicitly a read
 * or a write end. Rights make no such distinction -- any right can send
 * -- so "no senders left" is not a question this model can answer. "Am
 * I the only holder" is, and for a pipe it means the same thing.
 * In-flight rights still count, so a right on its way to a new writer
 * keeps it open. A pipe's creator must drop its own right, or eof never
 * arrives.
 */
static int
api_hungup(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r)
		return luaL_error(L, "bad right");

	lua_pushboolean(L, sole_holder(p, r->port));
	return 1;
}

/* sys.setexit(status): record this proc's exit status, reported to
 * whoever monitors it. Terminates nothing -- the proc ends however it
 * was going to. Split that way because a real exit must unwind from
 * arbitrary depth, which from C means raising, and any pcall in between
 * can swallow a raise. So lua implements os.exit as "record, then raise
 * a sentinel it catches itself".
 *   nil / 0   success
 *   n         posix status n, what a ported os.exit(1) gives
 *   "why"     plan 9's exits("why"), reported as status 1 as well
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

static int
api_time(lua_State *L)
{
	long long t = kernel_walltime();

	if (t == 0)
		lua_pushnil(L);
	else
		lua_pushinteger(L, (lua_Integer)t);
	return 1;
}

/* sys.settime(unix), gated on a right to clockport: handle "time" in
 * sys.granted(), as set_priority is gated on schedport.
 */
static int
api_settime(lua_State *L)
{
	lua_Integer t = luaL_checkinteger(L, 1);

	if (!proc_has_port(self(L), clockport))
		return luaL_error(L, "no clock capability");
	if (t <= 0)
		return luaL_error(L, "settime: not a unix time");

	lock(&timelock);
	wall_base_s = (long long)t - (long long)(uptime_ms() / 1000);
	unlock(&timelock);
	lua_pushinteger(L, t);
	return 1;
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

/* the real string.format, captured at proc_new before the chunk has run.
 * Its address is the registry key. Looking the function up at call time
 * would find whatever the proc last put there.
 */
static const char fmtkey = 0;

/* sys.log(fmt, ...) -- a line in the transcript. Ambient, and the tag
 * comes from the kernel, so no proc can lie about who wrote one. The
 * format is protected: killing the reporting proc over bad data is no
 * answer to it. */
static int
api_log(lua_State *L)
{
	struct kproc *p = self(L);
	const char *s = luaL_checkstring(L, 1);
	unsigned long long ms = uptime_ms();
	char buf[LOGLINE];

	int n = lua_gettop(L);

	if (n > 1) {
		/* copies to call with, so the arguments stay where they
		 * are: index 1 is what anchors `s` on the failure path,
		 * where the call has eaten everything it was passed.
		 */
		if (!lua_checkstack(L, n + 2))
			return 0;
		lua_rawgetp(L, LUA_REGISTRYINDEX, &fmtkey);
		for (int i = 1; i <= n; i++)
			lua_pushvalue(L, i);
		if (lua_pcall(L, n, 1, 0) == LUA_OK)
			s = lua_tostring(L, -1);
		else
			lua_pop(L, 1);	/* the format itself, then */
	}

	int wrote = snprintf(buf, sizeof buf, "[%5llu.%03llu] %s: %s\n",
	    ms / 1000, ms % 1000, p->name[0] ? p->name : "?", s);

	if (wrote < 0)
		return 0;

	size_t len = (size_t)wrote >= sizeof buf ? sizeof buf - 1 :
	    (size_t)wrote;

	/* a truncated line still ends one, or the next runs into it */
	if (buf[len - 1] != '\n')
		buf[len - 1] = '\n';
	kputs(buf);
	logput(buf, len);
	return 0;
}

/* sys.dmesg(from, max) -> data, next, dropped. One call copies at most
 * LOGCHUNK and a reader loops on the cursor it is handed, which bounds
 * the work done under the lock. */
static int
api_dmesg(lua_State *L)
{
	lua_Integer from = luaL_optinteger(L, 1, -1);
	lua_Integer max = luaL_optinteger(L, 2, LOGCHUNK);
	char buf[LOGCHUNK];
	unsigned long long start, dropped = 0;
	size_t n;

	if (max <= 0 || max > LOGCHUNK)
		max = LOGCHUNK;

	lock(&loglock);

	unsigned long long oldest = logoldest();

	if (from < 0 || (unsigned long long)from < oldest) {
		if (from >= 0)
			dropped = oldest - (unsigned long long)from;
		start = oldest;
	} else if ((unsigned long long)from > logseq) {
		start = logseq;
	} else {
		start = (unsigned long long)from;
	}

	n = (size_t)(logseq - start);
	if (n > (size_t)max)
		n = (size_t)max;
	if (n) {
		size_t o = (size_t)(start % LOGRING);
		size_t first = LOGRING - o < n ? LOGRING - o : n;

		memcpy(buf, logring + o, first);
		if (first < n)
			memcpy(buf + first, logring, n - first);
	}
	unlock(&loglock);

	lua_pushlstring(L, buf, n);
	lua_pushinteger(L, (lua_Integer)(start + n));
	lua_pushinteger(L, (lua_Integer)dropped);
	return 3;
}

/* sys.loginfo() -> seq, size, oldest, dropped */
static int
api_loginfo(lua_State *L)
{
	lock(&loglock);

	unsigned long long seq = logseq, oldest = logoldest(), lost = loglost;

	unlock(&loglock);

	lua_pushinteger(L, (lua_Integer)seq);
	lua_pushinteger(L, LOGRING);
	lua_pushinteger(L, (lua_Integer)oldest);
	lua_pushinteger(L, (lua_Integer)lost);
	return 4;
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
	{ "owned", api_owned },
	{ "sendright", api_sendright },
	{ "spawn", api_spawn },
	{ "monitor", api_monitor },
	{ "close", api_close },
	{ "stats", api_stats },
	{ "reclaim", api_reclaim },
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
	{ "log", api_log },
	{ "dmesg", api_dmesg },
	{ "loginfo", api_loginfo },
	{ "time", api_time },
	{ "settime", api_settime },
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
extern int luaopen_los_ninep(lua_State *L);	/* ninep.c: the 9P field codec */
extern int luaopen_los_crc(lua_State *L);		/* crc.c: crc16/crc32 */
extern int luaopen_los_font(lua_State *L);		/* font.c: glyphs */
extern int luaopen_los_buf(lua_State *L);		/* buf.c: byte buffers */
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

/* One los.sys call, counted. A wrapper at registration rather than an
 * increment inside each api_ function, because registration is the one
 * door: a syscall added to kapi later is counted without anyone
 * remembering to.
 *
 * Counts only, no cycles: two clock reads per syscall would be real
 * overhead on the cheapest ones. The line profile already prices the
 * line a syscall sits on; what it cannot say is how many calls that
 * line made, and which.
 */
static int
counted(lua_State *L)
{
	struct kproc *p = self(L);
	lua_CFunction f = (lua_CFunction)lua_touserdata(L,
	    lua_upvalueindex(1));

	/* Registration makes the index constant; bound it anyway as the
	 * second lock, so strip_debug's removal of setupvalue is not the
	 * only thing keeping it inside kproc.calls[]. */
	lua_Integer idx = lua_tointeger(L, lua_upvalueindex(2));

	if (p && idx >= 0 && idx < NSYSCALL)
		p->calls[idx]++;
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
	 * bootstrap it from. Every other capability is granted at
	 * whatever slot right_new picked and looked up by name through
	 * sys.granted(). Those numbers are not an abi.
	 *
	 * Hardcoding one aliases: an ungranted capability leaves an empty
	 * slot, and the first-free search hands it to the next child.
	 */
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "SELF");

	/* the ceiling on one message, so a client splitting a large
	 * payload can ask instead of carrying its own copy of the number.
	 * It bounds the whole message, not just the payload string, so a
	 * caller splitting to exactly MAXMSG still fails on the table
	 * around it. Leave room.
	 */
	lua_pushinteger(L, MAXMSG);
	lua_setfield(L, -2, "MAXMSG");
	return 1;
}

/* los.thread lives in src/thread.c. */
int luaopen_los_thread(lua_State *L);

/* ---- proc lifecycle ---- */

/* chunks for the lua heap, through the platform's pool. The machine
 * loses about a quarter again on top of every byte the heap believes it
 * mapped, and kheap_stats cannot see it, because the pool's metadata is
 * not ours.
 *
 * Taking whole pages instead looks like the obvious fix and measures
 * substantially worse, flat across chunk sizes: the pool reuses pages
 * it already holds better than we ask for new ones. Do not retry it
 * without measuring both.
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

/* ---- pooled bytes ----
 *
 * los.buf takes storage from the chunk source rather than a proc's lua
 * heap, so kalloc never sees it. It is charged here against the same
 * cap: a proc that can allocate outside its budget has no budget.
 * buf_used counts the same bytes again on their own, because memory
 * that is not in the numbers is memory nobody finds. Every counter
 * belongs to one proc, so nothing here needs a lock.
 */
int
kbuf_charge(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	if (p->mem_limit && p->mem_used + n > p->mem_limit)
		return 0;
	p->mem_used += n;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	p->buf_used += n;

	/* pace the collector by these bytes: a proc that only receives
	 * buffers holds megabytes of them while its lua heap looks idle.
	 * gc_step takes the step, at the dispatch point where nothing is
	 * held -- a step here would run a finalizer under a bucket.
	 */
	p->gc_owed += n;
	return 1;
}

void
kbuf_uncharge(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	p->mem_used -= n;
	p->buf_used -= n;
}

/* pooled bytes a proc may allocate between collector steps. Per proc
 * and unlocked, like every other counter here.
 */
#define GCDEBT	(64 * 1024)

int
kbuf_step_due(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	p->buf_debt += n;
	if (p->buf_debt < GCDEBT)
		return 0;
	p->buf_debt = 0;
	return 1;
}

size_t
kbuf_pooled(void)
{
	size_t total = 0;

	for (int i = 0; i < prochigh; i++)
		if (procv[i])
			total += procv[i]->buf_used;
	return total;
}


/* the string hash seed every state is built with. See src/coreg.h.
 *
 * Computed on the first call and kept, which needs no lock: the boot
 * proc's state is made before smp_start_aps runs, so the boot cpu has
 * already been here by the time a second one exists.
 */
unsigned int
kernel_strseed(void)
{
	static unsigned int seed;

	if (seed == 0) {
		unsigned long long t = platform_ticks();

		/* never 0: that is the "not drawn yet" value above */
		seed = (unsigned int)(t ^ (t >> 32)) | 1u;
	}
	return seed;
}

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
	/* growth only, and the test is what makes it so: gc_owed is
	 * unsigned, so adding a shrink wraps it to near SIZE_MAX.
	 */
	if (nsize > real_osize)
		p->gc_owed += nsize - real_osize;
	return q;
}

/* where a lua warning goes. Without one, lua drops them: lua_newstate
 * leaves warnf null and only luaL_newstate installs a default.
 *
 * The warning that matters here is an error inside a __gc handler. Lua
 * runs a finalizer protected and reports failure through this path
 * rather than raising, so with no warn function a finalizer that throws
 * is invisible -- no message, no counter, and the handle it was meant
 * to close stays open. A split message reads as two lines, since
 * joining them would need a buffer for a case that does not arise.
 */
static void
kernel_warn(void *ud, const char *msg, int tocont)
{
	struct kproc *p = ud;

	char b[256];

	(void)tocont;
	snprintf(b, sizeof b, "lua: %s: %s",
	    p && p->name[0] ? p->name : "?", msg);
	kernel_log(b);
}

/* one collector step, called through lua_pcall. The protection is not
 * decoration: a step allocates, and an allocation that cannot be served
 * raises. Reached from plain C that error finds no handler, and lua's
 * last resort is a panic function this state does not install, so it
 * aborts the machine for one proc that ran out of memory.
 */
static int
gc_step_k(lua_State *L)
{
	int kb = (int)lua_tointeger(L, lua_upvalueindex(1));

	lua_gc(L, LUA_GCSTEP, kb);
	return 0;
}

/* run the collector for one proc, at the one place it is allowed to.
 * The collector is stopped, so this is the only thing that advances it
 * and the only place a __gc handler can run. That is the point: such a
 * handler is arbitrary lua, and closing a handle is what they are for,
 * so it reaches port_unref on a port nobody named -- which needs every
 * bucket, and a caller holding one may not widen. Here nothing is held.
 * How often this runs is what paces it, not the size passed in: the
 * generational collector does one minor collection per call whatever
 * the debt says. The size still matters to an incremental one.
 */
static void
gc_step(struct kproc *p, lua_State *L, int mark)
{
	size_t kb;

	if (!L || p->gc_owed < GCSTEP_MIN)
		return;
	if (!lua_checkstack(L, 3))
		return;

	kb = p->gc_owed / 1024;
	p->gc_owed = 0;

	/* From the count hook this falls between two line events, and is
	 * charged to the interrupted line -- the heaviest allocator, which
	 * raises gc_owed fastest. From dispatch it is inside <scheduled>.
	 */
	if (mark)
		trace_mark(p, "<gc>");

	/* lua turns this back into bytes as an l_mem, which is 32 bits wide
	 * on esp32. Too large a step overflows it to a negative debt, and
	 * the collector reads that as credit and does nothing.
	 */
	if (kb > GCSTEP_MAX_KB)
		kb = GCSTEP_MAX_KB;

	lua_pushinteger(L, (lua_Integer)kb);
	lua_pushcclosure(L, gc_step_k, 1);
	if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
		const char *e = lua_tostring(L, -1);
		char b[256];

		snprintf(b, sizeof b, "lua: %s: gc: %s", p->name,
		    e ? e : "?");
		kernel_log(b);
		lua_pop(L, 1);
	}
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
	} else if (p->heap) {
		/* a shared heap keeps what this proc was using, because
		 * the chunks it sat in belong to the machine rather than
		 * to the proc. This is the one moment worth looking: a
		 * program that ran and exited has just dropped its whole
		 * working set, and the chunks it was carved from are
		 * empty now or never.
		 *
		 * Per-proc heaps need none of this -- destroy hands every
		 * chunk back at once.
		 */
		luaheap_reclaim(p->heap);
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
	/* the debug state names lua_States, so it dies with them. A
	 * corpse keeps both: proc_break does not come here.
	 */
	dbg_free(p);
}

/* lua's per-state creation and teardown hooks, from coreg.h.
 *
 * costart runs after lua has copied the new state's extra space, so the
 * kproc pointer is already right and only the links need setting.
 * cofree runs before the state's memory goes back, the last moment the
 * link is valid, and is reached for every coroutine. The main state is
 * created before the proc pointer exists, so it is not listed -- and
 * nothing needs to arm it, because the chunk runs in p->co.
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

/* the only place a hook mask is decided.
 *
 * LUA_MASKCOUNT is not conditional and must never become so: it is the
 * preemption budget, and a proc whose count hook went missing holds the
 * machine until it blocks. Tracing can only add LUA_MASKLINE to it, and
 * every lua_sethook here comes through this, so turning tracing off is
 * not a route to turning preemption off with it.
 */
static int
proc_hookmask(struct kproc *p)
{
	/* tracing and the debugger both want LUA_MASKLINE, which is why
	 * one place computes the mask: a second opinion would let one
	 * disarm the other, or disarm preemption.
	 */
	return LUA_MASKCOUNT
	    | ((p->trace || dbg_wants_lines(p->dbg)) ? LUA_MASKLINE : 0);
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

	/* The elapsed time belongs to the previous entry, not this one: a
	 * line hook fires before its line runs, so the interval between
	 * two hooks is the cost of the earlier line. Recording it against
	 * the arriving entry shifts the whole profile down by one, and
	 * names a line that is usually innocent and cheap.
	 *
	 * The newest entry carries zero until the next line arrives,
	 * which is honest: nothing has happened after it yet.
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

/* A marker entry, for something that is not a line of lua. A context
 * switch is the one that matters: without it the gap appears as a huge
 * wall delta on whichever line ran last, and the reader has to guess
 * whether that line was slow or the proc was not running. With it the
 * histogram has somewhere honest to put those intervals.
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

/* Leave the proc from wherever the hook fired. A yield reaches only
 * the resumer of its own state, so the trip out is forced one level
 * per instruction. Preemption and the debugger share it.
 */
static void
preempt_walkout(struct kproc *p, lua_State *L)
{
	if (p && L != p->co) {
		if (p->hookforced) {
			/* p->co is armed and still unreached, so the chain
			 * is deeper than one level: arm every coroutine
			 * and walk out one instruction per level.
			 */
			proc_armall(p, 1);
			p->hookforced = 2;
		} else {
			lua_sethook(p->co, preempt_hook, proc_hookmask(p),
			    1);
			p->hookforced = 1;
		}
	}
	/* the resumer never asked for this: kernel_cowrap reads the mark
	 * and resumes again, and src/thread.c handles the yield itself.
	 */
	if (p && L != p->co)
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
	lua_yield(L, 0);
}

/* the only preemption there is: no clock interrupt reaches a running
 * proc, so this fires every N lua instructions and yields once a
 * wall-clock quantum has passed. The instruction count is the sampling
 * rate, not the slice.
 *
 * It cannot fire inside a single C call, so string.rep("x", 1e8) holds
 * the machine for as long as it takes. Nothing here can fix that.
 */
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
		if (!p)
			return;
		if (p->trace)
			trace_line(p, L, ar);
		if (!p->dbg)
			return;
		dbg_line(p->dbg, L, ar);
		if (!atomic_load_explicit(&p->dbg->pending,
		    memory_order_relaxed))
			return;
		/* here, not at the next count event: a breakpoint leaves
		 * the state suspended at the line. A frame that cannot
		 * yield keeps pending set and stops later.
		 */
		if (lua_isyieldable(L))
			preempt_walkout(p, L);	/* does not return */
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

	/* the second safe point, and the one that paces the collector.
	 * The dispatch point runs once a slice, and a proc can allocate
	 * megabytes inside one slice -- stepping harder there cannot
	 * help, because the garbage is made after the step.
	 * A count hook is a legal place: it fires between two vm
	 * instructions, so no kernel function is on the stack and no
	 * bucket is held, and lua bars a finalizer from recursing into
	 * this hook. After the yieldable test on purpose -- a legal yield
	 * here is the cheapest evidence this is not a boundary.
	 */
	if (p)
		gc_step(p, L, 1);

	/* torture: stop this thread between every pair of instructions.
	 * A race between a thread and thread.run is a window of one or
	 * two instructions, and whether a run lands in one depends on how
	 * finely the work gets cut, which is why this class of bug shows
	 * on slow hardware and not on fast.
	 * Threads only: the walk-out below is skipped, because a kernel
	 * round trip per instruction turns a ten second test into an
	 * afternoon. So a tortured proc does not honor its quantum while
	 * a thread runs, and is PRIV_BOOT only for that reason.
	 */
	if (p && p->torture && L != p->co) {
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
		lua_yield(L, 0);
		return;		/* not reached */
	}

	/* a stop outranks the quantum: a swallowed one from this hook,
	 * or one the debugger asked for while the proc was running.
	 */
	int stopping = 0;

	if (p && p->dbg) {
		struct kdbg *d = p->dbg;

		if (atomic_load_explicit(&d->pending, memory_order_relaxed))
			stopping = 1;
		else if (atomic_load_explicit(&d->stopreq,
		    memory_order_relaxed)) {
			dbg_arm_stop(d, L, ar, DBG_REQ, 0);
			stopping = 1;
		}
	}

	if (!stopping && p && p->resumed && quantum_cycles &&
	    platform_ticks() - p->resumed < quantum_cycles)
		return;		/* under quantum: let it keep the cpu */

	/* A yield reaches only the resumer of the state the hook fired
	 * in. For a thread that is the proc's own scheduler, so yielding
	 * here hands the cpu back to thread.run and the proc keeps the
	 * machine -- a spinner in a thread starves everything else.
	 * Lua has no yield-across-levels, so the trip is forced: arm the
	 * proc's outermost state to fire on its next instruction, and the
	 * hook fires again with L == p->co, where a yield does reach the
	 * kernel. That also leaves the choice of what runs next with
	 * thread.run, where it belongs.
	 */
	preempt_walkout(p, L);
}

static int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file,
    int reductions, size_t mem_limit, int port_limit, int priv)
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
	p->buf_used = 0;
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
	/* No placement: there is one run queue for the machine, so
	 * whichever cpu looks next runs this proc, and takes it again
	 * whenever it is next runnable.
	 *
	 * p->home records where it last ran, set by run_proc -- plan 9's
	 * affinity rather than a placement. Nothing decides anything from
	 * it today; it answers "which cpu is this on" for the smp tests,
	 * and soft affinity would be a use of exactly this field.
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
	 *
	 * Incremental rather than the default generational, and gc_step
	 * depends on it: genstep does one minor collection per call and
	 * ignores the step size it is given, where incstep loops until the
	 * debt is paid and so honors it.
	 */
	lua_gc(p->L, LUA_GCINC, GCPAUSE, 0, 0);

	lua_setwarnf(p->L, kernel_warn, p);

	/* the collector runs where this kernel says and nowhere else.
	 * Left alone, lua collects inside an allocation, which puts an
	 * arbitrary __gc handler in the middle of whatever was
	 * allocating -- and closing a handle is what those handlers are
	 * for, so it reaches port_unref on a port that code never named.
	 * Stopping it makes that impossible rather than avoided.
	 * Two collections still happen unasked, and both are wanted: an
	 * emergency one on allocation failure, and lua_close running
	 * pending finalizers, which closes a dying proc's handles.
	 */
	lua_gc(p->L, LUA_GCSTOP);

	/* where self() finds the proc, set before any thread exists so
	 * lua_newthread copies it in. The whole record, not just the
	 * pointer: the links are copied from here too, so they must start
	 * empty.
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

	/* before the chunk has run, so what sys.log formats with is the
	 * real one whatever the proc does to string.format later.
	 */
	lua_getglobal(p->L, "string");
	lua_getfield(p->L, -1, "format");
	lua_rawsetp(p->L, LUA_REGISTRYINDEX, &fmtkey);
	lua_pop(p->L, 1);

	/* self port = right handle 0 */
	struct kport *port = port_new();

	if (!port || right_new(p, port, 1) != 0) {
		if (port)
			port->used = 0;	/* no rights were taken */
		proc_freestate(p);
		return -1;
	}
	p->selfidx = port->idx;
	p->selfgen = port->gen;

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

	/* ambient to require and gated per call: every function names a
	 * target and checks a right to it, so the module is not authority.
	 */
	lua_pushcfunction(p->L, luaopen_los_dbg);
	lua_setfield(p->L, -2, "los.dbg");

	/* crypto.native: chacha20, poly1305, sha-256, sha-512, aes.
	 * Ambient, unlike everything below it: authority is an argument
	 * here rather than the function, since it computes on a key the
	 * caller supplies and does nothing for a caller without one.
	 * Contrast los.platform.rng, where the raw draw is the capability.
	 * The C file is a verbatim copy from the ssh tree, where it is
	 * developed and where the RFC vectors run against both the C and
	 * the lua implementations. Keep it identical so the sync stays a
	 * copy and the check stays a diff.
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

	/* los.ninep (src/ninep.c), ambient on the same argument: the 9P
	 * field layout is fixed by the protocol and reaches nothing.
	 * lib/ninep.lua keeps the whole codec in Lua as ninep.pure and
	 * answers the same, more slowly.
	 */
	lua_pushcfunction(p->L, luaopen_los_ninep);
	lua_setfield(p->L, -2, "los.ninep");

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
	/* los.buf (src/buf.c): memory, not authority. A buffer is bytes a
	 * proc allocates from its own budget, so it is ambient for the
	 * same reason los.font is -- what it can reach is nothing it did
	 * not make.
	 */
	lua_pushcfunction(p->L, luaopen_los_buf);
	lua_setfield(p->L, -2, "los.buf");
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

	lua_pushcfunction(p->L, luaopen_los_thread);
	lua_setfield(p->L, -2, "los.thread");

	lua_pop(p->L, 2);	/* preload, package */

	/* ninep (lib/ninep.lua) is found via plain require("ninep") --
	 * LUA_PATH search, ordinary fopen() -- same as any other module.
	 * it used to need a preload workaround here because reading was
	 * disk-gated; now that read is ambient (see stdio.c's fopen),
	 * that workaround is gone and require() just works.
	 */

	/* every proc but proc 0 loses the file half of io, and loadfile
	 * and dofile with it. lib/nsio.lua puts io.open back over the
	 * proc's namespace, so a proc reaches exactly what was mounted for
	 * it and a proc given none cannot open a file at all.
	 *
	 * Removing the reference is the mechanism, not a check inside it:
	 * a function that is not there cannot be called wrong. The console
	 * half stays. Proc 0 keeps everything, because it builds the root
	 * namespace and has none to be confined to until it has.
	 */
	if (priv != PRIV_BOOT) {
		lua_pushcfunction(p->L, confine_proc);
		if (lua_pcall(p->L, 0, 0, 0) != LUA_OK) {
			kputs("proc confine error: ");
			kputs(lua_tostring(p->L, -1));
			kputs("\n");
			lua_pop(p->L, 1);
			right_drop(p, &p->rights[0]);
			proc_freestate(p);
			return -1;
		}
	}

	/* every proc, boot included: lua does not schedule the collector. */
	kernel_confine_gc(p->L);

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
		right_drop(p, &p->rights[0]);
		proc_freestate(p);
		return -1;
	}

	/* the lua runtime (los.thread) is a preloaded module now, pulled in
	 * on demand by require("los.thread") -- no auto-run bootstrap.
	 */
	lua_sethook(p->co, preempt_hook, proc_hookmask(p), p->reductions);
	p->priv = priv;
	p->mem_limit = mem_limit;
	p->port_limit = port_limit;
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

	/* born hatching: a proc runs only once its creator launches it.
	 *
	 * The caller still has to finish building it -- the spawn arg and
	 * nargs, a driver's device right, the boot proc's grants. A
	 * second cpu that dispatches it inside that window resumes a
	 * half-built proc and races the creator for its stack.
	 */
	p->status = HATCHING;
	nlive++;
	return p->id;
}

/* let a built proc run. Separate from proc_new because every caller has
 * setup to do first; one that forgets this leaves a proc blocked with
 * nothing able to wake it.
 */
static void
proc_launch(struct kproc *p)
{
	make_ready(p);		/* caller holds an ipc bucket */
}

/* build and deliver an exit notification: {exit=pid, normal=bool,
 * reason=string?, broke=true?} to the watcher's self port. broke=true
 * arrives while the corpse is still held, so a watcher can read the
 * stack of the pid it was just told about, and reap it when done.
 */
/* caller holds ipclock: proc_detach has it, the noproc path takes it.
 * locking here as well hangs any teardown with a watcher attached.
 */
static void
notify_exit(struct kproc *watcher, int pid, const char *reason, int status,
    const char *exitmsg, int broke, int priv)
{
	/* `reason` and `exitmsg` are the dying proc's own text, the only
	 * part of this notice that is its data rather than the fact of its
	 * death, so they go only to a watcher that held a right to it when
	 * it asked. That a proc exited stays ambient: a child watching the
	 * parent that spawned it holds no right to that parent and must
	 * not need one. An emptied reason still reads as an abnormal exit,
	 * so a watcher learns its peer died badly without learning what it
	 * said. priv is 1 for a synthetic notice, where the reason is our
	 * answer rather than anything a proc said.
	 */
	if (!priv) {
		reason = reason ? "" : 0;
		exitmsg = 0;
	}

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
	if (port_push_owned(watcher->rights[0].port, w.p, w.len, 0, 0, 0, 0))
		free(w.p);
	return;
fail:
	free(w.p);
}

/* everything dying does except freeing the state.
 *
 * The split exists for BROKE: a corpse stops being part of the machine
 * the instant it dies -- off the run queue, holding no rights, monitors
 * told -- and only then lingers. Deferring any of that to the reaper
 * makes a corpse a hazard: a parent would block in sys.monitor forever,
 * and a broke fileserver would wedge every client.
 * Only lua_close is deferred, so a __gc finalizer runs after its rights
 * are gone. They tolerate it, and one that fails is swallowed.
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
			right_drop(p, r);
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
			    why ? 0 : p->exitmsg, broke, p->wpriv[i]);
	}
	p->nwatch = 0;

	/* a debugger holds no monitor, so it is told here -- both deaths
	 * reach this, under the wide lock port_push wants.
	 */
	if (p->dbg)
		dbg_notify(p, DBG_RUN, 1);
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

	/* Read first, so a lap with no key takes no lock: the scheduler
	 * calls this on every pass.
	 */
	c = platform_kbd_read();
	if (c < 0)
		return;

	/* Every bucket, because port_push asks for that: it carries
	 * IPC_ASSERT_LOCKED, which is the whole-lock demand, not
	 * IPC_ASSERT_PORT. Narrowing this means narrowing port_push
	 * first. Held across the drain.
	 */
	ipclock_enter();
	do {
		/* serialized one-char string, as pump_keyboard sends: a
		 * port carries serialized values and the reader
		 * deserializes whatever arrives.
		 */
		unsigned char msg[6] = { 'S', 1, 0, 0, 0, 0 };

		msg[5] = (unsigned char)c;
		port_push(devkbdport, msg, sizeof msg, 0, 0);
	} while ((c = platform_kbd_read()) >= 0);
	ipclock_leave();
}

/* the pointer, onto its own port. What goes out is plan 9's mouse
 * record: 'm' and four fixed-width fields -- x, y, buttons, and a
 * millisecond clock. Fixed width so a reader asks for one record's
 * worth and gets exactly one event, needing no framing rule of its own.
 *
 * The driver coalesces, so this pushes at most one message per lap and
 * that message is the current state.
 */
static void
pump_devptr(void)
{
	int x = 0, y = 0, b = 0;
	char rec[64];
	int n;

	if (!devptrport)
		return;
	if (!platform_ptr_read(&x, &y, &b))
		return;

	/* four fields of twelve -- a space and eleven digits -- after the
	 * 'm', which is 49 bytes. The width is the framing rule, so a
	 * record of another size is a record no reader can trust.
	 */
	n = snprintf(rec, sizeof rec, "m%12d%12d%12d%12d",
	    x, y, b, (int)(platform_ticks() / 1000));
	if (n != 49)
		return;

	/* a serialized string, as the keyboard pump sends: 'S', the
	 * length, then the bytes.
	 */
	{
		unsigned char msg[5 + sizeof rec];
		int i;

		msg[0] = 'S';
		msg[1] = (unsigned char)(n & 0xff);
		msg[2] = (unsigned char)((n >> 8) & 0xff);
		msg[3] = (unsigned char)((n >> 16) & 0xff);
		msg[4] = (unsigned char)((n >> 24) & 0xff);
		for (i = 0; i < n; i++)
			msg[5 + i] = (unsigned char)rec[i];

		/* every bucket, as pump_devkbd takes: port_push carries
		 * IPC_ASSERT_LOCKED.
		 */
		ipclock_enter();
		port_push(devptrport, msg, (size_t)(5 + n), 0, 0);
		ipclock_leave();
	}
}

static void
pump_keyboard(void)
{
	EFI_INPUT_KEY key;

	/* Poll before locking: the scheduler calls this every lap and
	 * nearly every lap has no key, where taking the lock is the whole
	 * cost of the call.
	 */
	if (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) != EFI_SUCCESS)
		return;

	ipclock_enter();
	do {
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
	} while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_SUCCESS);
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
	devptrport = platform_have_ptr() ? port_new() : 0;
	serport = port_new();
	diskport = port_new();
	ethport = port_new();
	schedport = port_new();
	clockport = port_new();
	dbgport = port_new();
	ipclock_leave();
	if (!kbdport || !serport || !diskport || !schedport || !ethport ||
	    !clockport || !dbgport)
		return -1;
	/* kernel refs: the pumps (and, for diskport/schedport, the kernel
	 * itself) hold these ports forever
	 */
	kbdport->nrights++;
	if (devkbdport)
		devkbdport->nrights++;
	if (devptrport)
		devptrport->nrights++;
	serport->nrights++;
	diskport->nrights++;
	ethport->nrights++;
	schedport->nrights++;
	clockport->nrights++;
	dbgport->nrights++;

	/* soft-fail: no card means no eth task is spawned later, like any
	 * other optional boot-time resource.
	 *
	 * On efi this unbinds the firmware's own network stack from the
	 * card, and has to: SNP has one receive queue and no fan-out, so a
	 * stack left bound eats frames we never see. There is nothing to
	 * fall back to -- one stack, ours, on every platform.
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
	int pid = proc_new(path, 0, chunkname, 1, 0, 0, 0, priv);
	char buf[160];

	if (pid < 0) {
		snprintf(buf, sizeof buf,
		    "%s: FAILED to start; %s unavailable this boot",
		    chunkname + 1, what);
		kernel_log(buf);
		return -1;
	}
	/* the device right first, then run it: the task cannot do its job
	 * without it.
	 */
	struct kproc *p = find_proc(pid);

	if (p) {
		if (devport)
			right_new(p, devport, devrecv);
		proc_launch(p);
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

/* one row per driver task the boot payload gets a right to. Whether a
 * row is enabled is decided by the probes in kernel_init, before this
 * table is built: a one-shot boot-time table, not a runtime bus and
 * match-and-attach registry. Disk and sched are not here, having no
 * owner task -- they are bare capability ports granted to init.
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

	/* this task needs to draw random bytes. The raw draw is the
	 * capability, so it goes to as few procs as possible -- only the
	 * boot proc by default. But tcp cannot do without one: RFC 6528
	 * wants an initial sequence number that is neither a counter nor
	 * derivable from another connection's, or an off-path attacker
	 * who guesses it can inject into the stream. lib/tcb.lua refuses
	 * to invent one, having no clock and no secret, so the task that
	 * owns the connections must be able to.
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
		 * re-serving it over a port. Unlike every other backend
		 * here, what it serves is not a filesystem but one file,
		 * /data, that is the disk. Whatever reads a filesystem out
		 * of those bytes mounts this and knows nothing of virtio.
		 *
		 * No devport: nothing routes this device's interrupt, so
		 * there is no wakeup to deliver, and its reads and writes
		 * yield and re-poll instead.
		 */
		{ .path = "/task/blksrv.lua", .chunkname = "=blksrv",
		  .priv = PRIV_BLK, .devport = 0, .devrecv = 0,
		  .what = "the block device", .enabled = have_blk,
		  .capname = "blk" },
		/* the writable flash, as a filesystem. The proc doing the
		 * filesystem owns the device, so a sector is a call and not
		 * a message, and there is no block server between them.
		 */
		{ .path = "/task/fatsrv.lua", .chunkname = "=fatsrv",
		  .priv = PRIV_FLASH, .devport = 0, .devrecv = 0,
		  .what = "the flash filesystem", .enabled = have_flash,
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

	int pid = proc_new(code, len, "=init", is_file, 0, 0, 0, PRIV_BOOT);

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
	/* likewise the pointer: a receive right, and only one of it. */
	if (devptrport)
		grant_named(p, "ptr", devptrport, 1);
	grant_named(p, "disk", diskport, 0);
	grant_named(p, "sched", schedport, 0);
	grant_named(p, "time", clockport, 0);
	grant_named(p, "dbg", dbgport, 0);

	/* granted: the boot proc reads its rights table on its first
	 * line, so it runs only now.
	 */
	if (p)
		proc_launch(p);
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

/* exponentially weighted average of the fraction of wall time this proc
 * spent running, in per-mille, from measured cycles. Lazy: the decay is
 * a closed form over the elapsed interval, so a proc untouched for
 * seconds decays correctly in one call and nothing sweeps.
 *
 * See docs/scheduling.md for why this is cycles rather than an instruction
 * count, and for the two arithmetic traps below.
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
	/* straight from cycles, never through whole milliseconds: the
	 * truncation is a systematic undercount at lap scale, where the
	 * interval is a handful of milliseconds.
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
 * equal share, clamped to the proc's static weight. Plan 9's
 * reprioritize, with weight playing basepri's part. A proc using its
 * share lands at its weight, a hog sinks toward zero, and one that has
 * been starved clamps to the top. Nobody is demoted by a rule.
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

/* the run queues: one pair for the machine, not one pair per cpu, so
 * any cpu takes the next runnable proc from the same place and there is
 * no placement decision to make at spawn. `runq` is the lap in
 * progress, `donq` what has had a turn, and dispatch_lap swaps them.
 *
 * schedlock guards both, and every cpu's current/idle/dispatching with
 * them -- a reader of those is always deciding something about these
 * queues at the same time. It is the contention ceiling above a few
 * cpus, and docs/scheduling.md has the measurements and the two ways out.
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

/* mark a proc runnable and price it, which is plan 9's ready(). The
 * priority is computed here rather than at dispatch, so the dispatcher
 * only reads an int and reprioritize runs once per wakeup instead of
 * once per ready proc per lap. That needs a decay independent of how
 * often it is sampled, since wakeups are irregular where laps are not.
 */
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

	/* a held proc, or a corpse, is not made runnable by a message.
	 * The wake is not lost: the waiter stays linked and the message
	 * queued, and cont resumes into the block that re-polls.
	 */
	if (p->status == STOPPED || p->status == BROKE) {
		unlock(&schedlock);
		return;
	}

	/* a blocked proc runs no hook, so its wake delivers the stop: it
	 * wakes into the stop rather than into execution. dbg_sweep
	 * sends the notice; here we hold schedlock and a bucket.
	 */
	if (p->dbg && p->status == BLOCKED &&
	    atomic_exchange_explicit(&p->dbg->stopreq, 0,
	    memory_order_relaxed)) {
		p->status = STOPPED;
		p->dbg->reason = DBG_REQ;
		atomic_store_explicit(&p->dbg->notify, DBG_REQ,
		    memory_order_relaxed);
		unlock(&schedlock);
		return;
	}

	/* which queue p is already on, read under the lock: another cpu
	 * takes procs off these, so a read from outside can name a queue
	 * p has already left.
	 */
	struct rqset *keep = p->onq;

	/* p may be running on another cpu right now. Enqueueing it would
	 * put it on a bucket while that cpu still holds it, and dispatch
	 * enqueues it again when the resume returns -- one proc on two
	 * buckets, and a run queue that no longer terminates.
	 * So leave it to the cpu running it: marking it READY is enough,
	 * because dispatch requeues on exactly that and gives the proc
	 * back under this same lock, so one of the two always sees the
	 * other. Ask the proc, not the cpus, for the reason in
	 * proc_running.
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

/* run the proc's sys.atexit handlers, last first, on the main state:
 * p->co has finished, but the list lives in p->L's registry.
 *
 * Nothing sets cpu_self()->current here. This runs inside run_proc,
 * which published it for the whole resume, and clearing it mid-resume
 * is what make_ready must not see -- it would enqueue a proc that
 * dispatch still holds. Errors are swallowed as a finalizer's are,
 * since there is no caller left to report them to.
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

/* resume one READY proc, spending its whole weight. Returns 1 if it ran
 * at all, which is what tells the caller the machine is not idle.
 */
static int
run_proc(struct kproc *p)
{
	int ran = 0;

	/* a proc with weight above 1 is resumed that many times in a row
	 * before dispatch moves on. The whole programmable-scheduler
	 * surface is this loop bound reading an int.
	 */
	for (int w = 0; w < p->weight; w++) {
		/* collect the waits left behind by whoever woke this proc,
		 * before any lua runs. Before the resume rather than
		 * after, because the double-block test reads the same
		 * list: stale entries read as "already blocked".
		 */
		wait_reap(p);

		/* this cpu owns p, so it is the only place the hooks can
		 * be disarmed without racing the target's execution.
		 */
		dbg_settle(p);

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

		/* drain the 16-byte rx fifo, on a deadline rather than
		 * after every resume. A proc can run a full hook window
		 * before yielding and a lap can carry LAPSPILL dispatches,
		 * so the serial pump is no tight bound on how long the fifo
		 * goes undrained -- hence a drain here as well.
		 * The drain itself is a port i/o trap, and doing it per
		 * resume cost most of a cross-proc round trip. A deadline
		 * well inside the fifo's fill time keeps the guarantee for
		 * two clock reads and a compare.
		 */
		unsigned long long now = platform_ticks();

		if (now - last_uart_drain >= uart_drain_cycles) {
			uart_poll();
			last_uart_drain = platform_ticks();
		}
		if (rc == LUA_YIELD) {
			lua_pop(p->co, nres);
			/* before the READY test: a stop leaves the queue
			 * by the rule everything else does.
			 */
			if (dbg_commit(p))
				break;	/* held by a debugger */
			if (p->status != READY)
				break;	/* now BLOCKED */
			continue;	/* spend more weight */
		}
		if (rc == LUA_OK) {
			run_atexit(p);
			proc_kill(p, 0);
		}
		else if (rc == LUA_ERRMEM)
			/* no traceback here: lua reports out of memory
			 * through a preallocated message so that it never
			 * allocates to report having no memory, and building
			 * a traceback would break that and fail again. It
			 * still breaks rather than dies -- such a corpse is
			 * the one most worth reading, and sys.stack allocates
			 * nothing in a target.
			 */
			proc_break(p, lua_tostring(p->co, -1));
		else {
			/* a coroutine that errors out of lua_resume does not
			 * unwind its stack, which is what lets the traceback
			 * be walked here, after resume returned. The error
			 * object is on the stack: read it before the
			 * traceback replaces the top.
			 * Built here as well as held in the corpse, because
			 * this is what reaches the log -- the corpse answers
			 * a question someone thought to ask, the log answers
			 * the one nobody was there for.
			 */
			const char *errmsg = lua_tostring(p->co, -1);

			luaL_traceback(p->co, p->co, errmsg, 0);
			proc_break(p, lua_tostring(p->co, -1));
		}
		break;	/* proc died, nothing left to resume */
	}
	return ran;
}

/* two-level poll backoff for com2, which no firmware event backs: a
 * faster period while bytes arrive, a slower one after a run of empty
 * polls, snapping back the instant a byte shows up.
 * These are measured, not requested. The firmware timer has a hard
 * floor at its own interrupt period, so anything below is silently
 * rounded up while anything above is honored accurately -- see
 * docs/uefi-notes.md. The slow period is the first-byte-after-idle
 * latency for interactive 9p over com2, so going slower is a latency
 * trade rather than free.
 */
#define TICK_FAST_100NS  100000		/* 10ms: the OVMF floor, measured */
#define TICK_SLOW_100NS  150000		/* 15ms, honored accurately */
#define TICK_IDLE_THRESHOLD 25		/* consecutive empty polls before backing off */

/* consecutive laps with nothing dispatched before the heap is swept.
 * Well past the gap between two messages of one exchange, so work is
 * never swept through.
 */
#define QUIET_SWEEP_LAPS 100

/* the watchdog window, and how often the lap pushes it back. Four pets
 * per window, so three consecutive misses are needed for a reset.
 */
#define WATCHDOG_SECS    60
#define WATCHDOG_PET_MS  15000

/* one phase of a lap: take procs by `take` until the bound runs out or
 * the queue is empty, running each one. Returns whether anything ran.
 *
 * Both phases are this loop, differing in how they choose and in what
 * bounds them. The bound is read at the first acquisition rather than
 * in one of its own, and the requeue of the proc just run shares the
 * acquisition that takes the next -- so a phase costs one acquisition
 * per proc rather than two. It is the acquisitions, not the work under
 * them, that cost; see the note over schedlock.
 */
static int
dispatch_phase(struct cpu *me, struct kproc *(*take)(struct rqset *), int floor)
{
	struct kproc *prev = 0;
	int budget = -1, i = 0, ran = 0;

	for (;;) {
		struct kproc *p = 0;

		lock(&schedlock);
		if (budget < 0) {
			budget = runq->n;
			if (budget < floor)
				budget = floor;
		}
		/* clearing current and deciding to requeue are one step:
		 * split them and a wakeup landing in between is either
		 * lost or enqueued twice.
		 */
		if (prev) {
			me->current = 0;
			prev->oncpu = 0;
			if (prev->status == READY && !prev->onq)
				rq_add(donq, prev);
			prev = 0;
		}
		/* a proc somebody is reading is put aside rather than run:
		 * see proc_freeze. Taken and set aside under the one lock,
		 * so it cannot be resumed between the two.
		 */
		while (i < budget && (p = take(runq)) && p->frozen) {
			rq_add(donq, p);
			i++;
		}
		if (i >= budget)
			p = 0;
		/* published under the lock and for the whole resume, so
		 * that make_ready can see this proc is in hand and leave
		 * the requeue above to do the enqueueing.
		 */
		if (p) {
			if (p->oncpu)
				platform_abort("proc dispatched on two cpus");
			p->oncpu = me->idx + 1;
			i++;
		}
		me->current = p;
		unlock(&schedlock);
		if (!p)
			break;		/* bound spent, or another cpu got there first */
		/* outside the lock, and this is the rule the whole
		 * scheme rests on: a resume runs lua, which can send,
		 * which takes the ipc lock and then this one. Holding
		 * this across it would invert that order and deadlock
		 * against any other cpu doing the same.
		 */
		if (run_proc(p))
			ran = 1;
		/* the collector's safe point, and the only one. Here
		 * rather than inside run_proc because nothing is held
		 * here, and no C local holds anything reachable only from
		 * lua -- run_proc's error paths carry lua strings while
		 * they build a traceback.
		 *
		 * After the resume, not before: a proc that blocks and is
		 * never woken reaches no point before its next resume, and
		 * its garbage would sit for as long as it stayed parked.
		 */
		gc_step(p, p->L, 0);
		prev = p;
	}
	return ran;
}

/* one lap of dispatch on one cpu: both phases, then the drain and the
 * swap. Every cpu that schedules runs this and nothing else. What the
 * boot processor does around it -- the device pumps, the timers, the
 * firmware tick -- is machine-wide work an AP must not touch, rather
 * than part of scheduling. Returns whether anything ran, which is what
 * the caller's idle decision rests on.
 */
static int
dispatch_lap(struct cpu *me)
{
	int ran = 0;

	/* phase one is bounded by how many were waiting when it started,
	 * so it cannot spin on procs it keeps waking.
	 */
	if (dispatch_phase(me, rq_take_high, 0))
		ran = 1;

	/* the bound is what makes the lap terminate at all: a proc woken
	 * mid-lap joins the current runq, so two procs feeding each
	 * other hand this phase a fresh proc every time it takes one. An
	 * unbounded drain never reaches the top of the loop again, where
	 * the timers and the device pumps live, and one busy pair would
	 * stop every timer on the machine. LAPSPILL is the floor that
	 * keeps the bound from being expensive.
	 */
	if (dispatch_phase(me, rq_take_any, LAPSPILL))
		ran = 1;

	/* where this cpu holds nothing; a null test per proc otherwise */
	dbg_sweep();

	/* the lap ends when runq is empty, and whichever cpu empties it
	 * says so. With one queue that is the only workable boundary: a
	 * cpu cannot swap on its own schedule without handing the others
	 * procs that already had a turn.
	 *
	 * Counting the cpus inside a lap and letting the last one out
	 * swap livelocks instead -- cpus finishing early re-enter at
	 * once, so they are never all out together, and every cpu churns
	 * empty laps over a runq whose procs all sit in donq.
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

/* what an application processor runs, and the whole of it. The boot
 * processor's loop is the same two phases wrapped in machine-wide work
 * -- device pumps, timers, the firmware tick -- and none of that is an
 * AP's business. Under efi it could not be: TPL is one cooperative lock
 * and an AP calling firmware is undefined, so this inherits that
 * division rather than inventing one.
 *
 * The idle is a real sleep, ended by the reschedule ipi make_ready
 * sends when it puts work on the queue.
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
		if (ipcheld_any())	/* see kernel_run; the same check */
			platform_abort("ipclock held across a lap");
		if (dispatch_lap(me)) {
			me->ndispatch++;
			continue;
		}

		/* nothing to run. Publish that under the lock, which is
		 * where make_ready reads it to decide whether to send the
		 * ipi, so this cannot sleep just after someone decided it
		 * did not need waking. The lock settles who decides; it
		 * does not close the window. An ipi sent the instant after
		 * the lock drops would be taken as an ordinary interrupt
		 * and lost, and the sleep would never end with work
		 * already queued. So interrupts go off before the queue is
		 * looked at, and stay off into platform_cpu_idle.
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
	int quiet_laps = 0, swept = 0;
	unsigned long long last_watchdog_ms = 0;

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

		/* nothing may hold the ipc lock across the top of a lap.
		 * This catches the release a lua error jumped past, which
		 * is the failure mode the lua-facing acquisitions have and
		 * which no amount of reading finds reliably.
		 * This cpu, not any cpu: another holding it here is
		 * ordinary. Any bucket, never every one: a leak is a
		 * single missed release, so demanding all eight asks
		 * whether this cpu is inside a wide region, which answers
		 * no for exactly the case this exists to catch.
		 */
		if (ipcheld_any())
			platform_abort("ipclock held across a lap");

		/* drain the periodic timer's signal. nothing is paced
		 * against it any more, but a tick that fires during a busy
		 * lap stays signaled otherwise, and the WaitForEvent below
		 * would then return at once instead of sleeping.
		 */
		if (tick)
			BS->CheckEvent(tick);

		/* push the watchdog back. Throttled: a lap is
		 * milliseconds and this is a firmware call.
		 */
		{
			unsigned long long now = uptime_ms();

			if (now - last_watchdog_ms >= WATCHDOG_PET_MS) {
				last_watchdog_ms = now;
				platform_watchdog(WATCHDOG_SECS);
			}
		}

		expire_timers();
		pump_eth();
		pump_keyboard();
		pump_devkbd();
		pump_devptr();
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
		/* two phases, and the split is the whole design. Phase one
		 * takes the highest priority first, so an interactive proc
		 * answers before a hog gets another turn. Phase two takes
		 * whatever is left, priority never consulted, including
		 * anything woken during phase one. Phase two is the
		 * starvation guarantee, deliberately independent of the
		 * priority function: a policy that is buggy or hostile can
		 * cost latency, but cannot wedge the machine. Both phases
		 * are bounded, and "had its turn" is membership in donq.
		 */
		ran = dispatch_lap(me);

		/* a quiet machine gives its heap back: the large-block
		 * cache is held against a next request that is not coming.
		 * Once per spell, since the sweep walks the free lists and
		 * would find nothing twice. No lua runs here, so unlike
		 * gc_step this needs no safe point.
		 */
		if (ran) {
			quiet_laps = 0;
			swept = 0;
		} else if (!swept && ++quiet_laps >= QUIET_SWEEP_LAPS) {
			swept = 1;
			heap_release_all();
		}

		if (!ran) {
			/* everyone blocked: sleep until a key, a frame, or
			 * the tick. Without the wire here a frame waits for
			 * the next tick, because the eth pump runs only at
			 * the top of a lap. ethwait may be 0, for no card or
			 * a driver publishing no event, and then the tick is
			 * the bound again.
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
