/* the run queues and what decides who runs. see docs/scheduling.md. */

#include <stdio.h>

#include "lock.h"
#include "cpu.h"
#include "kernel.h"
#include "kproc.h"
#include "ksched.h"
#include "timer.h"
#include "debug.h"
#include "platform.h"

/* fair-share averaging window. The mixing weight is n/D, which
 * approximates an exponential only while n stays small next to D, so
 * this must stay well above the lap period -- see docs/scheduling.md.
 */
#define SCHED_DECAY_MS	500

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
int
proc_freeze(struct kproc *p)
{
	int running;

	lock(&schedlock);
	p->frozen++;
	running = proc_running(p);
	unlock(&schedlock);
	return running;
}

void
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
int
proc_still_running(struct kproc *p)
{
	int running;

	lock(&schedlock);
	running = proc_running(p);
	unlock(&schedlock);
	return running;
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

	unsigned long long cput = atomic_load_explicit(&p->cputime,
	    memory_order_relaxed);
	unsigned long long used = cput - p->lastcpu;
	unsigned long long window = n > SCHED_DECAY_MS ? SCHED_DECAY_MS : n;
	/* straight from cycles, never through whole milliseconds: the
	 * truncation is a systematic undercount at lap scale, where the
	 * interval is a handful of milliseconds.
	 */
	unsigned long long denom = n * (kernel_cyc_per_ms() ? kernel_cyc_per_ms() : 1);
	unsigned frac = denom ? (unsigned)((used * 1000) / denom) : 0;

	if (frac > 1000)
		frac = 1000;

	p->cpu = (unsigned)(((unsigned long long)p->cpu *
	    (SCHED_DECAY_MS - window) + (unsigned long long)frac * window) /
	    SCHED_DECAY_MS);
	p->lastupdate = now;
	p->lastcpu = cput;
}

/* dynamic priority: inversely proportional to recent cpu use against an
 * equal share, clamped to the proc's static weight. Plan 9's
 * reprioritize, with weight playing basepri's part. A proc using its
 * share lands at its weight, a hog sinks toward zero, and one that has
 * been starved clamps to the top. Nobody is demoted by a rule.
 */
int
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
struct lock schedlock = LOCK_INIT;
static struct rqset schedq[2];
struct rqset *runq, *donq;

void
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

void
rq_add(struct rqset *set, struct kproc *p)
{
	int b = rq_bucket(p->pri);

	SCHED_ASSERT_LOCKED();
	TAILQ_INSERT_TAIL(&set->q[b], p, rqe);
	set->mask |= 1u << b;
	set->n++;
	p->onq = set;
}

void
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
struct kproc *
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
struct kproc *
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
void
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
void
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
void
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

		if (c && KSTAT_GET(c->idle) && c != cpu_self()) {
			wake = i;
			break;
		}
	}

	unlock(&schedlock);

	if (wake != ~0u)
		platform_wake_cpu(wake);
}

int
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
