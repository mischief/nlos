#ifndef KPROC_H
#define KPROC_H

/* the kernel's internal types: procs, ports, rights, waits. kernel.h is
 * the public surface, for platform code and stdio; this is for the
 * kernel's own modules. see docs/ipc.md, docs/proc.md and docs/locking.md.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <sys/queue.h>

#include "lua.h"
#include "kernel.h"
#include "param.h"

struct kdbg;
struct kextra;
struct kproc;
struct luaheap;
struct rqset;

#define MAXRIGHTS	512
#define NRIGHTS_INLINE	8
#define MAXDEPTH	16
#define MAXMSGRIGHTS	32
#define MAXMSGBUFS	4
#define MAXWATCH	8	/* monitors per proc */
#define NSYSCALL	64
#define TRACESRC	32	/* distinct source files remembered */
#define TRACECO		16	/* coroutines distinguished, as in debug.c */

/* one line a proc executed. both clocks come from one tsc read and are
 * deltas from the previous entry: cpu is cycles this proc ran, wall is
 * elapsed, so wall - cpu is how long it was not running.
 */
struct tracent {
	int line;
	unsigned short src;	/* index into ktrace.name */
	unsigned short co;	/* index into ktrace.co */
	/* u32 because consecutive lines are microseconds apart. these
	 * saturate rather than wrap.
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
	/* a one-entry cache on the source pointer, which is only ever
	 * compared: the string it names belongs to the target and may be
	 * collected.
	 */
	const void *lastsrc;
	int lastid;
	unsigned long long lastwall;	/* tsc at the previous entry */
	unsigned long long lastcpu;	/* running cycles at the previous entry */
	const void *co[TRACECO];
	int nco;
};

/* buffers travelling on one message. the bytes are not in the message:
 * the wire holds an index into this. the kernel owns them from the
 * moment a send is queued until a receiver takes them.
 */
struct msgbufs {
	void *p[MAXMSGBUFS];
	size_t len[MAXMSGBUFS];
	int n;
};

struct kmsg {
	struct kmsg *next;
	size_t len;
	struct msgbufs bufs;	/* transferred; freed by msg_free */
	size_t qcost;		/* what it took off MAXQUEUE */
	/* ports named by in-flight rights here. each holds a ref, so a
	 * port cannot be freed and its index reused while the only right
	 * to it sits in a queue.
	 */
	unsigned short refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];	/* was each one a recv right? */
	int nrefs;
	unsigned char *data;	/* owned; freed by msg_free */
};

struct kport {
	unsigned short idx;	/* its slot in portv; what the wire carries */
	int used;
	/* which port this slot has held, counted from 1 and never reused.
	 * slots are reused, so anything naming a port across time keeps
	 * the pair. see kproc.selfidx.
	 */
	unsigned long long gen;
	TAILQ_HEAD(, waiter) waiters;
	/* rights + in-flight refs + kernel refs, and the receive rights
	 * among them. atomic because serialize mints refs on arbitrary
	 * ports with no bucket held; port_unref still takes every bucket.
	 */
	atomic_int nrights;
	atomic_int nrecv;
	int dead;	/* no receive right left; sends are dropped */
	size_t qbytes;	/* queued payload, against MAXQUEUE */
	struct kmsg *head, *tail;

	/* counters for sys.ports(). full and dead are different faults: a
	 * slow reader, against a receive right closed mid-send. qpeak
	 * because a queue is rarely sampled at its worst moment.
	 */
	unsigned long long nsent;
	unsigned long long ndrop_full;
	unsigned long long ndrop_dead;
	size_t qpeak;

	/* who made it and where, so sys.ports() can name the call site
	 * behind a leak. inline and short because a lua string would have
	 * to outlive the port, and nothing guarantees that.
	 */
	char tag[16];
	char where[32];
};

struct right {
	struct kport *port;
	int recv;
	int used;
};

/* a capability the kernel granted at spawn, by name. handle numbers are
 * whatever right_new picked and are not an abi; lua reads the mapping
 * through sys.granted(). an absent key means "not this boot".
 */
struct grant {
	const char *name;
	int handle;
	SLIST_ENTRY(grant) e;	/* on proc->grants; walked whole */
};

/* a proc waiting on a port, one record per (proc, port) pair: an alt
 * waits on several at once, so the port's list and the proc's list each
 * need their own linkage. the pool is fixed and shared.
 */
struct waiter {
	struct kproc *p;
	struct kport *port;
	int send;			/* waiting for room, not for a message */
	/* still linked on port->waiters. a waker unlinks the entry it woke
	 * on and clears this; collecting the rest is the proc's own job.
	 * see wait_reap.
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
	/* the port behind handle 0: sys.kill and sys.reap ask whether the
	 * caller holds a right to it. named by (slot, generation), read
	 * through proc_selfport, 0 for none. no pointer back to the proc.
	 */
	unsigned short selfidx;
	unsigned long long selfgen;
	SLIST_HEAD(, waiter) waiters;	/* ports this proc is blocked on */
	/* almost every block waits on one port, so the first record is
	 * inline and costs no allocation. an alt takes the rest from the
	 * heap.
	 */
	struct waiter w0;
	int w0used;
	TAILQ_ENTRY(kproc) rqe;		/* on one of the dispatch sets */
	struct rqset *onq;		/* which, or null */
	/* the first NRIGHTS_INLINE handles live here, the rest in an array
	 * allocated only if a proc needs one. sys.stats().rightshigh
	 * reports the high water.
	 */
	struct right rights[NRIGHTS_INLINE];
	struct right *xrights;		/* MAXRIGHTS - NRIGHTS_INLINE, or null */
	int rhint;			/* lowest slot that might be free */
	int rhigh;			/* one past the highest slot ever used */
	int bufdenied;			/* the last -2 was a buffer, not a right */
	TAILQ_HEAD(, kextra) coros;	/* every lua_State of this proc */
	int hookforced;			/* 0 none, 1 p->co armed, 2 all armed */
	int torture;			/* yield between EVERY instruction */

	/* held still so another proc can read it: dispatch must not resume
	 * this proc. counted, so a second reader cannot thaw it under the
	 * first. guarded by schedlock, like `current`.
	 */
	int frozen;

	/* some port has claimed the right to wake this proc. several cpus
	 * may wake one alt at once, each under a different bucket; the
	 * winner takes this 0 to 1. cleared by wait_reap. see docs/locking.md.
	 */
	atomic_int woken;

	/* which cpu has this proc in hand, plus one, or zero for none. one
	 * proc is one thread of control; see docs/proc.md for what rests
	 * on it. written under schedlock at both ends.
	 */
	unsigned oncpu;

	int watchers[MAXWATCH];	/* pids to notify when this proc dies */
	/* did each watcher hold a right to this proc when it asked?
	 * decided at sys.monitor, not at death: a supervisor closes its
	 * spawn right and should still hear how the child ended.
	 */
	unsigned char wpriv[MAXWATCH];
	int nwatch;
	struct luaheap *heap;	/* this proc's lua heap; see kalloc */
	/* which cpu dispatches this proc -- not p->cpu, which is a
	 * percentage. queues live on the home cpu, so make_ready enqueues
	 * against this from whichever cpu is sending.
	 */
	unsigned home;
	int reductions;		/* instruction budget per slice */
	/* args on co's stack for the first resume only: sys.spawn's `arg`,
	 * received by the chunk as `...`. zeroed after that resume.
	 */
	int nargs;
	size_t mem_used;	/* live bytes in this proc's lua heap, plus its
				 * pooled buffer bytes -- see kbuf_charge */
	size_t buf_used;	/* the pooled half of mem_used, on its own */
	size_t buf_debt;	/* pooled bytes since the last collector step */
	size_t mem_peak;
	size_t mem_limit;	/* 0 = unlimited */
	/* receive rights held, against a cap inherited like mem_limit.
	 * counted as what the proc holds rather than what it made, which
	 * is unix's rule for RLIMIT_NOFILE. handle 0 counts.
	 */
	int nports;
	int nports_peak;
	int port_limit;		/* 0 = unlimited */
	/* bytes lua has asked for since this proc's collector last ran.
	 * the collector is stopped, so gc_step reads this instead of
	 * lua's GCdebt. growth only: a free is not a reason to collect.
	 */
	size_t gc_owed;
	/* bytes asked for since this proc was last collected whole, which
	 * is what says an idle collect has anything to find. Separate from
	 * gc_owed because a step zeroes that one and frees only part of
	 * what it accounted for.
	 */
	size_t gc_idle_owed;
	/* when this proc last ran, for deciding it has really parked
	 * rather than paused. Milliseconds and not laps: a lap is
	 * microseconds under load and a tick when idle, so a lap count
	 * means a different wait on a busy machine than on a quiet one.
	 */
	unsigned long long gc_idle_ms;
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
	/* how often this proc was given the cpu, against cputime's how
	 * long: the same milliseconds over thousands of resumes is a proc
	 * round-tripping on ipc, over a handful is one working in a block.
	 */
	unsigned long long nresume;
	/* named capabilities, read by name through sys.granted(). a list
	 * because the boot payload holds a dozen and every other proc
	 * holds none. appended at spawn, walked whole, never indexed.
	 */
	SLIST_HEAD(, grant) grants;
	struct ktrace *trace;	/* line trace ring, or 0; see sys.set_trace */
	struct kdbg *dbg;	/* a debugger holds it, or 0; see los.dbg */

	/* los.sys calls made, indexed by position in kapi[]. see counted()
	 * for why it is a wrapper, and sys.syscalls to read it. always on:
	 * it is per live proc, and arming it would defeat the point.
	 */
	unsigned int calls[NSYSCALL];
	unsigned int brokeseq;	/* death order, so the cap reaps the oldest */
	int exitcode;		/* sys.setexit(); reported by notify_exit */
	int exiting;		/* sys.exit(); the dispatch loop ends it */
	char exitmsg[64];	/* plan 9 style exits("why"); "" if unused */
	int weight;		/* WRR share, 1..MAXWEIGHT, see sys.set_priority */
	int priv;		/* PRIV_*; only PRIV_BOOT keeps raw file access */
};

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

/* device capabilities: which classes of hardware a proc may reach.
 *
 * A set rather than one value, because a task can own two devices and
 * be right to -- fatsrv lays FAT on the flash and on the card both, and
 * a second proc for the second device is a second copy of lib/fat.
 */
enum {
	PRIV_NONE	= 0,

	/* proc 0 and nothing else. not a device capability: it means raw
	 * ESP access reaches this proc, which is what lets it build the
	 * root namespace every other proc inherits.
	 */
	PRIV_BOOT	= 1 << 0,

	PRIV_ESP	= 1 << 1,
	PRIV_CONS	= 1 << 2,
	PRIV_WIRE	= 1 << 3,
	PRIV_POWER	= 1 << 4,
	PRIV_P9		= 1 << 5,
	PRIV_ETH	= 1 << 6,
	PRIV_FB		= 1 << 7,
	PRIV_BLK	= 1 << 8,
	PRIV_FLASH	= 1 << 9,
};

/* does this cpu hold a given bucket, every bucket, or any bucket at
 * all. Not lock.h's holding(), which answers for the machine: under smp
 * another cpu holding a bucket is ordinary and says nothing about
 * whether this one may touch the ports under it.
 */
int	ipcheld_one_port(struct kport *p);
int	ipcheld(void);
int	ipcheld_any(void);

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
	if (!ipcheld_one_port(p)) {				\
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

/* the state a per-state record belongs to: the record sits immediately
 * before it, which is what lua_getextraspace computes in reverse.
 */
static inline lua_State *
kx_state(struct kextra *kx)
{
	return (lua_State *)((char *)kx + LUA_EXTRASPACE);
}

/* the ipc lock, as buckets hashed on port index. enter() takes every
 * bucket ascending; enter_port() takes the one covering p, and obliges
 * the caller to touch no other port and allocate no lua memory.
 */
void	ipclock_enter(void);
void	ipclock_leave(void);
void	ipclock_enter_port(struct kport *p);
void	ipclock_leave_port(struct kport *p);

extern struct kport *portv[MAXPORTS];

/* queue a message on a port, copying `data`. refs/nrefs are in-flight
 * right refs and may be null. Caller holds the bucket covering `port`.
 */
int	port_push(struct kport *port, const unsigned char *data, size_t len,
	    const unsigned short *refs, int nrefs);

/* drop one reference; the last one frees the port. Wide: dropping the
 * last reference flushes the queue, which reaches other ports.
 */
void	port_unref(struct kport *port);

/* write a string to the console, unstamped. kernel_log is the stamped
 * form, and is what a diagnostic line should use.
 */
void	kputs(const char *s);

/* the longest line the transcript keeps, and the writer behind
 * kernel_log. Nothing called from here may log: a second entry with
 * the lock held sits on itself forever.
 */
#define LOGLINE	1024
void	logput(const char *s, size_t n);

/* the transcript behind sys.log, read back by sys.dmesg. */
size_t	kernel_dmesg(long long from, char *out, size_t max,
	    unsigned long long *next, unsigned long long *dropped);
void	kernel_loginfo(unsigned long long *seq, size_t *size,
	    unsigned long long *oldest, unsigned long long *lost);

/* the capability tokens: reserved ports that carry no message, where
 * holding any right to one is the authorization. Null where the
 * machine has no such device this boot.
 */
extern struct kport *diskport;
extern struct kport *schedport;
extern struct kport *clockport;

/* the debug capability: a right to this debugs any proc, which is what
 * reaches a boot service, since nothing holds a right to init's
 * children but init.
 */
extern struct kport *dbgport;

/* the debugger state a proc carries, freed with its lua_States, and
 * the notice its holder gets. Defined with the rest of los.dbg.
 */
void	dbg_free(struct kproc *p);
void	dbg_notify(struct kproc *p, int reason, int exited);

struct right *right_slot(struct kproc *p, int h);
struct right *right_get(struct kproc *p, lua_Integer h);
int	right_new(struct kproc *p, struct kport *port, int recv);
void	right_drop(struct kproc *p, struct right *r);

#endif
