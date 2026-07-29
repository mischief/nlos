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
#include "kernel.h"
#include "net.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "platform.h"

#define MAXPROCS	32
#define MAXPORTS	128
#define MAXRIGHTS	64
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

enum { DEAD, READY, BLOCKED };
/* PRIV_BOOT is proc 0 and nothing else. it is not a device capability
 * like the rest -- it means "this proc is where the raw ESP reaches",
 * which is true only of the proc the kernel starts itself, and is what
 * lets it build the root namespace every other proc inherits.
 */
enum { PRIV_NONE, PRIV_BOOT, PRIV_ESP, PRIV_CONS, PRIV_WIRE, PRIV_POWER,
    PRIV_TCP, PRIV_UDP };

struct kmsg {
	struct kmsg *next;
	size_t len;
	/* ports referenced by in-flight rights in this message. they hold
	 * a ref each so a port can't be freed (and its index reused) while
	 * the only right to it sits in a queue.
	 */
	unsigned char refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];	/* was each one a recv right? */
	int nrefs;
	unsigned char *data;	/* owned; freed by msg_free */
};

struct kport {
	int used;
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

/* a proc holds at most MAXRIGHTS distinct rights, so it can never park
 * on more than that many distinct ports; size the wait set to match so
 * a legitimate gather can't be rejected.
 */
#define MAXWSET MAXRIGHTS

struct kproc {
	int status;
	int id;			/* unique forever; slots are reused, ids not */
	lua_State *L;		/* owning state */
	lua_State *co;		/* thread the chunk runs on */
	struct kport *waiting;	/* blocked on this port */
	struct kport *wset[MAXWSET];	/* or on any of these (alt) */
	int nwset;
	struct right rights[MAXRIGHTS];
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
	int exitcode;		/* sys.setexit(); reported by notify_exit */
	char exitmsg[64];	/* plan 9 style exits("why"); "" if unused */
	int weight;		/* WRR share, 1..MAXWEIGHT, see sys.set_priority */
	int priv;		/* PRIV_*; only PRIV_BOOT keeps raw file access */
};

static struct kproc procs[MAXPROCS];
static struct kport ports[MAXPORTS];
static struct kport *kbdport;
static int nlive;
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
    size_t len, const unsigned char *refs, int nrefs);
static int port_push_owned(struct kport *port, unsigned char *data,
    size_t len, const unsigned char *refs, const unsigned char *refrecv,
    int nrefs);

extern unsigned long long platform_ticks(void);
extern void malloc_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);
static void port_unref(struct kport *port);
static void wake_receivers(struct kport *port);
static void proc_kill(struct kproc *p, const char *why);
static int reprioritize(struct kproc *p, int nrunnable);
static int count_runnable(void);
static void make_ready(struct kproc *p);

/* release a right that was serialized into a message but never
 * delivered (send failed, or the queue was flushed). a receive right in
 * flight was counted in nrecv when it was serialized, so it has to be
 * uncounted here -- and BEFORE port_unref, which decides port death by
 * looking at nrecv.
 */
static void
release_inflight(const unsigned char *refs, const unsigned char *refrecv,
    int n)
{
	for (int i = 0; i < n; i++) {
		struct kport *port = &ports[refs[i]];

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

static void
calibrate_clock(void)
{
	unsigned long long t0 = platform_ticks();

	BS->Stall(100000);	/* 100ms */

	unsigned long long dt = platform_ticks() - t0;

	cyc_per_ms = dt / 100;
	if (cyc_per_ms == 0)
		cyc_per_ms = 1;	/* refuse to divide by zero later */
	quantum_cycles = cyc_per_ms * QUANTUM_MS;
	calibrate_reductions();
}

/* milliseconds since calibrate_clock(). the one time base timers and
 * timeouts are denominated in.
 */
static unsigned long long
uptime_ms(void)
{
	return platform_ticks() / cyc_per_ms;
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
		if (procs[i].status != DEAD && procs[i].id == pid)
			return &procs[i];
	return 0;
}

extern void console_write(const char *s, size_t n);
void luaL_openlibs(lua_State *L);	/* our linit */

static void
kputs(const char *s)
{
	console_write(s, strlen(s));
}

/* ---- ports and rights ---- */

static struct kport *
port_new(void)
{
	for (int i = 0; i < MAXPORTS; i++)
		if (!ports[i].used) {
			ports[i].used = 1;
			ports[i].head = ports[i].tail = 0;
			ports[i].nrights = 0;
			ports[i].nrecv = 0;
			ports[i].dead = 0;
			ports[i].qbytes = 0;
			return &ports[i];
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
		port_flush(port);
		port->used = 0;
		port->dead = 0;
		port->nrights = 0;
		port->nrecv = 0;
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
	wake_receivers(port);
}

static int
right_new(struct kproc *p, struct kport *port, int recv)
{
	for (int i = 0; i < MAXRIGHTS; i++)
		if (!p->rights[i].used) {
			p->rights[i].used = 1;
			p->rights[i].port = port;
			p->rights[i].recv = recv;
			port->nrights++;
			if (recv)
				port->nrecv++;
			return i;
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
	if (h < 0 || h >= MAXRIGHTS || !p->rights[h].used)
		return 0;
	return &p->rights[h];
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
	unsigned char refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];
	int nrefs;
};

static int
wput(struct wbuf *w, const void *src, size_t n)
{
	if (w->len + n > w->cap) {
		size_t ncap = w->cap ? w->cap * 2 : 256;

		while (ncap < w->len + n)
			ncap *= 2;
		if (ncap > MAXMSG)
			return -1;
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
			unsigned char pi = (unsigned char)(r->port - ports);

			if (wbyte(w, 'R') || wbyte(w, pi))
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
		if (*off + 2 > len)
			return -1;
		unsigned char pi = p[(*off)++];
		unsigned char recv = p[(*off)++];

		if (pi >= MAXPORTS || !ports[pi].used)
			return -1;
		int h = right_new(receiver, &ports[pi], recv);

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

static void
wake_receivers(struct kport *port)
{
	for (int i = 0; i < MAXPROCS; i++) {
		struct kproc *p = &procs[i];

		if (p->status != BLOCKED)
			continue;
		if (p->waiting == port)
			goto wake;
		for (int j = 0; j < p->nwset; j++)
			if (p->wset[j] == port)
				goto wake;
		continue;
wake:
		p->waiting = 0;
		p->nwset = 0;
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
    const unsigned char *refs, const unsigned char *refrecv, int nrefs)
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
    const unsigned char *refs, int nrefs)
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

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));
	struct wbuf w = { 0 };

	if (!r)
		return luaL_error(L, "bad right");
	luaL_checkany(L, 2);
	if (serialize(L, 2, &w, p, 0)) {
		/* release refs taken for rights serialized before the
		 * failure point
		 */
		release_inflight(w.refs, w.refrecv, w.nrefs);
		free(w.p);
		return luaL_error(L, "unserializable message");
	}
	if (r->port->dead) {
		release_inflight(w.refs, w.refrecv, w.nrefs);
		free(w.p);
		lua_pushboolean(L, 0);	/* dead port: dropped */
		return 1;
	}
	int rc = port_push_owned(r->port, w.p, w.len, w.refs, w.refrecv,
	    w.nrefs);

	if (rc == -2)	/* w.p already freed by port_push_owned */
		return luaL_error(L, "port queue full");
	if (rc)
		return luaL_error(L, "out of memory queueing message");
	lua_pushboolean(L, 1);
	return 1;
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
	struct kmsg *m = r->port->head;

	r->port->head = m->next;
	if (!r->port->head)
		r->port->tail = 0;
	r->port->qbytes -= m->len;

	size_t off = 0;

	lua_pushboolean(L, 1);
	if (deserialize(L, m->data, m->len, &off, p, 0)) {
		msg_free(m);
		return luaL_error(L, "corrupt message");
	}
	/* receiver now holds its own refs (right_new); drop in-flight */
	msg_free(m);
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
	p->status = BLOCKED;
	p->waiting = r->port;
	return lua_yield(L, 0);
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

	p->nwset = 0;
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, luaL_checkinteger(L, -1));

		lua_pop(L, 1);
		if (!r || !r->recv)
			return luaL_error(L, "altblock: bad receive right");
		if (r->port->head) {
			p->nwset = 0;
			return 0;	/* already ready, don't sleep */
		}
		/* dedup: the caller may list the same handle more than once
		 * (alt cases share ports). distinct ports are bounded by
		 * MAXRIGHTS == MAXWSET, so the set can never overflow.
		 */
		int seen = 0;
		for (int j = 0; j < p->nwset; j++)
			if (p->wset[j] == r->port) {
				seen = 1;
				break;
			}
		if (!seen)
			p->wset[p->nwset++] = r->port;
	}
	p->status = BLOCKED;
	return lua_yield(L, 0);
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
    int status, const char *exitmsg);

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
	size_t mem_limit = 0;
	char chunkname[32] = "=spawn";

	if (!lua_isnoneornil(L, 2)) {
		luaL_checktype(L, 2, LUA_TTABLE);
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

	if (!target) {
		notify_exit(p, pid, "noproc", -1, 0);
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
	return 0;
}

static void preempt_hook(lua_State *L, lua_Debug *ar);

/* install the kernel's count hook on a coroutine. lua-side hook
 * functions cannot yield ("attempt to yield across a C-call
 * boundary"), so in-state schedulers (los.thread) must use this to
 * preempt busy threads.
 */
static int
api_preempt(lua_State *L)
{
	lua_State *co = lua_tothread(L, 1);
	lua_Integer count = luaL_optinteger(L, 2, default_reductions);

	if (!co)
		return luaL_error(L, "preempt: not a coroutine");
	lua_sethook(co, preempt_hook, LUA_MASKCOUNT, (int)count);
	return 0;
}

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
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	return 3;
}

static int
api_stats(lua_State *L)
{
	int nports = 0, nprocs = 0;

	for (int i = 0; i < MAXPORTS; i++)
		if (ports[i].used)
			nports++;
	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status != DEAD)
			nprocs++;
	lua_createtable(L, 0, 3);
	lua_pushinteger(L, nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, nprocs);
	lua_setfield(L, -2, "procs");
	lua_pushinteger(L, (lua_Integer)nidle);
	lua_setfield(L, -2, "idles");

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
		if (procs[i].status != DEAD) {
			lua_pushinteger(L, procs[i].id);
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
	case READY:
		lua_pushliteral(L, "ready");
		return 1;
	case BLOCKED:
		if (p->waiting) {
			lua_pushfstring(L, "port#%d",
			    (int)(p->waiting - ports));
			return 1;
		}
		if (p->nwset > 0) {
			luaL_Buffer b;

			luaL_buffinit(L, &b);
			luaL_addstring(&b, "alt[");
			for (int i = 0; i < p->nwset; i++) {
				char tmp[16];

				snprintf(tmp, sizeof tmp, "%s%d",
				    i ? "," : "",
				    (int)(p->wset[i] - ports));
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

	lua_State *co = p->co;
	lua_Debug ar;
	int n = 0;

	lua_newtable(L);
	for (int level = 0; level < MAXFRAMES; level++) {
		if (!lua_getstack(co, level, &ar))
			break;
		if (!lua_getinfo(co, "Sln", &ar))
			break;

		lua_createtable(L, 0, 4);
		lua_pushstring(L, ar.short_src);
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, ar.currentline);
		lua_setfield(L, -2, "line");
		lua_pushstring(L, ar.name ? ar.name : "?");
		lua_setfield(L, -2, "name");
		lua_pushstring(L, ar.what ? ar.what : "?");
		lua_setfield(L, -2, "what");
		lua_rawseti(L, -2, ++n);
	}
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
	{ "tryrecv", api_tryrecv },
	{ "block", api_block },
	{ "altblock", api_altblock },
	{ "yield", api_yield },
	{ "newport", api_newport },
	{ "spawn", api_spawn },
	{ "monitor", api_monitor },
	{ "close", api_close },
	{ "stats", api_stats },
	{ "meminfo", api_meminfo },
	{ "preempt", api_preempt },
	{ "self", api_self },
	{ "procs", api_procs },
	{ "granted", api_granted },
	{ "name", api_procname },
	{ "wchan", api_wchan },
	{ "stack", api_stack },
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
extern int luaopen_los_platform_cons(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_wire(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_power(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_tcp(lua_State *L);	/* net.c */
extern int luaopen_los_platform_udp(lua_State *L);	/* net.c */

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
	return 1;
}

/* ---- proc lifecycle ---- */

/* lua allocator with per-proc accounting. note lua's convention: when
 * ptr is NULL, osize carries the object type, not a size.
 */
static void *
kalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	struct kproc *p = ud;
	size_t real_osize = ptr ? osize : 0;

	if (nsize == 0) {
		free(ptr);
		p->mem_used -= real_osize;
		return 0;
	}
	/* enforce the limit only on growth so gc/shrink always succeeds */
	if (p->mem_limit && nsize > real_osize &&
	    p->mem_used - real_osize + nsize > p->mem_limit)
		return 0;

	void *q = realloc(ptr, nsize);

	if (!q)
		return 0;
	p->mem_used += nsize - real_osize;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	return q;
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
static void
preempt_hook(lua_State *L, lua_Debug *ar)
{
	struct kproc *p = *(struct kproc **)lua_getextraspace(L);

	(void)ar;
	if (!lua_isyieldable(L))
		return;
	if (p && p->resumed && quantum_cycles &&
	    platform_ticks() - p->resumed < quantum_cycles)
		return;		/* under quantum: let it keep the cpu */
	lua_yield(L, 0);
}

static int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file,
    int reductions, size_t mem_limit, int priv)
{
	struct kproc *p = 0;

	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status == DEAD) {
			p = &procs[i];
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
		lua_close(p->L);
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
	}

	if (luaL_loadfile(p->L, "/lib/thread.lua") == LUA_OK) {
		lua_setfield(p->L, -2, "los.thread");
	} else {
		kputs("los.thread load error: ");
		kputs(lua_tostring(p->L, -1));
		kputs("\n");
		lua_pop(p->L, 1);
	}

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
		lua_close(p->L);
		return -1;
	}

	/* the lua runtime (los.thread) is a preloaded module now, pulled in
	 * on demand by require("los.thread") -- no auto-run bootstrap.
	 */
	lua_sethook(p->co, preempt_hook, LUA_MASKCOUNT, p->reductions);
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
	p->status = READY;
	p->waiting = 0;
	nlive++;
	return p->id;
}

/* build and deliver an exit notification: {exit=pid, normal=bool,
 * reason=string?} to the watcher's self port.
 */
static void
notify_exit(struct kproc *watcher, int pid, const char *reason, int status,
    const char *exitmsg)
{
	struct wbuf w = { 0 };
	unsigned int npairs = 3;
	lua_Integer id = pid;
	lua_Integer st = status;

	if (reason)
		npairs++;
	if (exitmsg && exitmsg[0])
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
	port_push_owned(watcher->rights[0].port, w.p, w.len, 0, 0, 0);
	return;
fail:
	free(w.p);
}

static void
proc_kill(struct kproc *p, const char *why)
{
	char reason[224];

	/* copy the reason out: it usually points into the lua state we
	 * are about to close
	 */
	if (why) {
		snprintf(reason, sizeof reason, "%s", why);

		char buf[256];

		snprintf(buf, sizeof buf, "proc %d died: %s\n", p->id,
		    reason);
		kputs(buf);
	}
	lua_close(p->L);
	p->status = DEAD;
	p->L = 0;
	p->co = 0;
	nlive--;

	/* release every right this proc held; ports lose refs, orphaned
	 * queues flush, unreferenced ports free
	 */
	for (int i = 0; i < MAXRIGHTS; i++)
		if (p->rights[i].used)
			right_drop(&p->rights[i]);

	/* erlang-style DOWN: tell the watchers */
	for (int i = 0; i < p->nwatch; i++) {
		struct kproc *w = find_proc(p->watchers[i]);

		if (w)
			notify_exit(w, p->id, why ? reason : 0,
			    why ? -1 : p->exitcode,
			    why ? 0 : p->exitmsg);
	}
	p->nwatch = 0;
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
	calibrate_clock();	/* before anything measures a duration */
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

	if (pid < 0) {
		char buf[128];

		snprintf(buf, sizeof buf,
		    "warning: %s failed to start; %s is unavailable "
		    "this boot\n", chunkname + 1, what);
		kputs(buf);
		return -1;
	}
	if (devport) {
		struct kproc *p = find_proc(pid);

		if (p)
			right_new(p, devport, devrecv);
	}
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
		{ .path = "/lib/cons.lua", .chunkname = "=cons",
		  .priv = PRIV_CONS, .devport = kbdport, .devrecv = 1,
		  .what = "console", .enabled = 1, .capname = "cons" },
		{ .path = "/lib/wire.lua", .chunkname = "=wire",
		  .priv = PRIV_WIRE, .devport = serport, .devrecv = 1,
		  .what = "the 9p wire", .enabled = 1, .capname = "wire" },
		/* the esp server: the only proc that reaches the disk
		 * directly. it gets diskport at handle 1, so writes are
		 * possible here and nowhere else.
		 */
		{ .path = "/lib/espsrv.lua", .chunkname = "=esp",
		  .priv = PRIV_ESP, .devport = diskport, .devrecv = 0,
		  .what = "the esp filesystem", .enabled = 1,
		  .capname = "esp" },
		{ .path = "/lib/power.lua", .chunkname = "=power",
		  .priv = PRIV_POWER, .devport = 0, .devrecv = 0,
		  .what = "reset/stall", .enabled = 1, .capname = "power" },
		/* no NIC (real hardware, or qemu -net none) is the normal
		 * case, not a boot failure -- don't even try spawning a task
		 * that could never listen/dial successfully. tcp and udp are
		 * two separate exclusive tasks (see PRIV_TCP/PRIV_UDP),
		 * soft-failing independently of each other.
		 */
		{ .path = "/lib/tcp.lua", .chunkname = "=tcp",
		  .priv = PRIV_TCP, .devport = netport, .devrecv = 1,
		  .what = "networking (tcp)", .enabled = have_net,
		  .capname = "tcp" },
		{ .path = "/lib/udp.lua", .chunkname = "=udp",
		  .priv = PRIV_UDP, .devport = udpport, .devrecv = 1,
		  .what = "networking (udp)", .enabled = have_udp,
		  .capname = "udp" },
	};
	size_t ndrivers = sizeof drivers / sizeof drivers[0];
	int pids[sizeof drivers / sizeof drivers[0]];
	size_t i;

	for (i = 0; i < ndrivers; i++) {
		pids[i] = drivers[i].enabled
		    ? spawn_driver(drivers[i].path, drivers[i].chunkname,
		          drivers[i].priv, drivers[i].devport,
		          drivers[i].devrecv, drivers[i].what)
		    : -1;
	}

	int pid = proc_new(code, len, "=init", is_file, 0, 0, PRIV_BOOT);

	if (pid < 0)
		return pid;

	struct kproc *p = find_proc(pid);

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
static void
make_ready(struct kproc *p)
{
	p->status = READY;
	p->pri = reprioritize(p, count_runnable());
}

static int
count_runnable(void)
{
	int n = 0;

	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status == READY)
			n++;
	return n;
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
		uart_poll();
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
			 */
			proc_kill(p, lua_tostring(p->co, -1));
		else {
			/* a coroutine that errors out of lua_resume
			 * deliberately does NOT unwind its stack -- that's
			 * what lets luaL_traceback walk it right here, same
			 * trick xpcall's message handler relies on, just done
			 * from the C side after resume already returned
			 * instead of during unwinding.
			 *
			 * error object is on the stack; read it before
			 * proc_kill closes the state.
			 */
			const char *errmsg = lua_tostring(p->co, -1);

			luaL_traceback(p->co, p->co, errmsg, 0);
			proc_kill(p, lua_tostring(p->co, -1));
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
		/* two distinct negatives, and conflating them was a real bug:
		 * PRI_SKIP means "not READY when the lap started", PRI_RAN
		 * means "already had its turn". with one marker for both, a
		 * proc woken DURING phase 1 still carried the snapshot's
		 * marker and phase 2 skipped it -- so the guarantee did not
		 * guarantee, and every IPC round trip waited an extra lap.
		 * cost 45% on cross-proc latency, invisible to a
		 * single-proc throughput test.
		 */
		enum { PRI_SKIP = -1, PRI_RAN = -2 };

		int pri[MAXPROCS];
		int nready = 0;

		/* priority was computed when each proc became ready (see
		 * make_ready), so this only reads it -- plan 9's ready()
		 * files a proc at its priority and runproc() just picks.
		 */
		for (int i = 0; i < MAXPROCS; i++) {
			if (procs[i].status == READY) {
				pri[i] = procs[i].pri;
				if (pri[i] < 0)
					pri[i] = 0;
				nready++;
			} else {
				pri[i] = PRI_SKIP;
			}
		}
		(void)nready;

		/* phase 1: by priority, highest first */
		for (int picked = 0; picked < nready; picked++) {
			int best = -1;

			for (int i = 0; i < MAXPROCS; i++)
				if (pri[i] >= 0 &&
				    procs[i].status == READY &&
				    (best < 0 || pri[i] > pri[best]))
					best = i;
			if (best < 0)
				break;
			pri[best] = PRI_RAN;
			if (run_proc(&procs[best]))
				ran = 1;
		}

		/* phase 2: the guarantee. no priority consulted. */
		for (int i = 0; i < MAXPROCS; i++) {
			struct kproc *p = &procs[i];

			if (p->status != READY || pri[i] == PRI_RAN)
				continue;
			pri[i] = PRI_RAN;
			if (run_proc(p))
				ran = 1;
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
	for (int i = 0; i < MAXRIGHTS; i++)
		if (p->rights[i].used && p->rights[i].port == port)
			return 1;
	return 0;
}

int
kernel_current_has_disk(void)
{
	return proc_has_port(current_proc, diskport);
}
