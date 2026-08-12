#ifndef SCHED_H
#define SCHED_H

/* the run queues and what decides who runs. see docs/scheduling.md. */

#include "cpu.h"
#include "kproc.h"

/* sys.set_priority clamp, and the priority resolution per unit of
 * weight: a default-weight proc gets a range to move in rather than a
 * choice of two values.
 */
#define MAXWEIGHT	16
#define PRI_BASE	10

/* the two dispatch sets. runq is the lap in progress, donq what has
 * already had a turn, and dispatch_lap swaps them.
 */
extern struct rqset *runq, *donq;

/* guards the queues, and every cpu's current/idle/dispatching with them:
 * a reader of those is always deciding something about these queues at
 * the same time. Order is ipc, then this.
 */
extern struct lock schedlock;

void	rq_init(void);
void	rq_add(struct rqset *set, struct kproc *p);
void	rq_del(struct kproc *p);
struct kproc *rq_take_high(struct rqset *set);
struct kproc *rq_take_any(struct rqset *set);

/* mark a proc runnable and price it. Caller holds an ipc bucket. */
void	make_ready(struct kproc *p);

/* park a running proc, or take a dying one off its queue. proc_block's
 * caller holds ipclock; ipc then sched is the allowed order.
 */
void	proc_block(struct kproc *p);
void	proc_unqueue(struct kproc *p);

/* what a proc's fair share says its priority should be, and how many
 * procs that share is divided among.
 */
int	reprioritize(struct kproc *p, int nrunnable);
int	count_runnable(void);

/* hold a proc still so another may read it. proc_freeze returns whether
 * the target is running right now, raising `frozen` either way, so the
 * caller may wait and ask proc_still_running again with no window in
 * between. Every freeze needs a matching thaw.
 */
int	proc_freeze(struct kproc *p);
int	proc_still_running(struct kproc *p);
void	proc_thaw(struct kproc *p);

#endif
