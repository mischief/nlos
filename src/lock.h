#ifndef LOCK_H
#define LOCK_H

/* the mutual exclusion this kernel has, which on a uniprocessor is
 * none.
 *
 * Everything here compiles to a compiler barrier when NCPU is 1, and
 * NCPU is 1 everywhere except x86_64 microvm. That is not a
 * concession: a lock whose cost is invisible on the platforms that
 * cannot have a second cpu is what lets kernel.c stay one file with no
 * #ifdefs in it. The barrier is not nothing -- it stops the compiler
 * hoisting a load out of a critical section, which is a real bug on
 * one cpu too.
 *
 * The lock is a ticket lock, not a test-and-set. A test-and-set is
 * shorter and is the wrong shape: it hands the lock to whichever cpu's
 * cache line happens to win, so under contention one waiter can be
 * passed over indefinitely. This kernel already refuses that trade
 * once, in the scheduler -- phase 2 of a lap exists so that a runnable
 * proc cannot be starved by policy -- and a lock that can starve a cpu
 * would put the guarantee back at risk from underneath. A ticket lock
 * serves in arrival order for two extra instructions.
 *
 * LOCK ORDER, and it is the whole discipline:
 *
 *	pmm  ->  port  ->  cpu runq
 *
 * Take them left to right, release in any order. Two locks of the same
 * class are taken in ascending address order, which today happens in
 * exactly one place: an idle cpu stealing from another cpu's runq.
 * Nothing takes two port locks -- the multi-port paths (alt) hold one
 * at a time and re-validate, which is what altrecv_take's comment
 * ("the two passes below are one critical section ... when a lock
 * arrives it goes around both") was written in anticipation of.
 *
 * Nothing here masks interrupts. A lock that an interrupt handler also
 * takes needs that, and this kernel has none: an isr bumps a counter
 * or fills a single-producer ring, and the scheduler polls it at the
 * top of a lap. Keeping it that way is cheaper than making every lock
 * pay for a case that does not exist. The one place that does need to
 * shut an isr out -- uart.c's ring drain -- masks IF directly and says
 * so, and is on the boot cpu at both ends.
 */

#include "machine.h"

#ifndef NCPU
#define NCPU 1
#endif

#if NCPU > 1

#include <stdatomic.h>

struct lock {
	atomic_uint next;	/* the ticket the next arrival takes */
	atomic_uint owner;	/* the ticket being served */
};

#define LOCK_INIT { 0, 0 }

static inline void
lock(struct lock *l)
{
	unsigned t = atomic_fetch_add_explicit(&l->next, 1,
	    memory_order_relaxed);

	while (atomic_load_explicit(&l->owner, memory_order_acquire) != t)
		machine_relax();
}

static inline void
unlock(struct lock *l)
{
	unsigned t = atomic_load_explicit(&l->owner, memory_order_relaxed);

	atomic_store_explicit(&l->owner, t + 1, memory_order_release);
}

/* take the lock if it is free, without queueing for it. The idle path
 * uses this to look at another cpu's runq: failing to get it means
 * that cpu is busy, which is itself the answer, and blocking to find
 * out would be worse than not asking.
 */
static inline int
canlock(struct lock *l)
{
	unsigned t = atomic_load_explicit(&l->owner, memory_order_relaxed);
	unsigned n = t;

	return atomic_compare_exchange_strong_explicit(&l->next, &n, t + 1,
	    memory_order_acquire, memory_order_relaxed);
}

static inline int
holding(const struct lock *l)
{
	return atomic_load_explicit(&l->next, memory_order_relaxed) !=
	    atomic_load_explicit(&l->owner, memory_order_relaxed);
}

#else	/* NCPU == 1 */

struct lock {
	char unused;
};

#define LOCK_INIT { 0 }

#define barrier() __asm__ volatile ("" ::: "memory")

static inline void lock(struct lock *l) { (void)l; barrier(); }
static inline void unlock(struct lock *l) { (void)l; barrier(); }
static inline int canlock(struct lock *l) { (void)l; barrier(); return 1; }
static inline int holding(const struct lock *l) { (void)l; return 1; }

#endif

#endif
