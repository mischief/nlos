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
 *	ipc  ->  sched  ->  pmm
 *
 * Take them left to right, release in any order. pmm is last because
 * it is a leaf: nothing is ever acquired while holding it, and almost
 * everything needs memory while holding something else -- port_push
 * allocates a message body with an ipc lock held, and proc_new builds
 * a whole lua_State that way. An earlier version of this comment put
 * pmm first while describing it as innermost, which are opposite
 * claims; innermost is the true one.
 *
 * sched is one lock for the machine, not one per cpu, because the run
 * queues are one pair for the machine. See kernel.c.
 *
 * ipc is not one lock either. It is an array of buckets hashed on the
 * port index, and taking several of them is ordinary rather than
 * forbidden: the callers that can reach a port they cannot name in
 * advance take every bucket, ascending. Two rules make that safe, and
 * they are stated where they can be checked, in docs/locking.md and
 * over the bucket array in kernel.c. The one to know before touching
 * anything here: a caller holding one bucket may never ask for the
 * wide form, because the wide form starts at bucket zero and would
 * deadlock against anyone coming the other way.
 *
 * So two locks of the same class do get taken, in ascending index --
 * the ipc buckets. An earlier version of this comment said nothing
 * ever took two port locks, and named an idle cpu stealing from
 * another cpu's runq as the one same-class case. Neither is true now:
 * there is one run queue, so there is nothing to steal.
 *
 * Nothing here masks interrupts, and the two are separate questions
 * rather than one: this lock excludes the OTHER cpus, and masking IF
 * excludes THIS cpu's own handler. A lock an isr also takes needs
 * both, and gets them by masking around the lock at the call site --
 * uart.c's rx ring is the one place, and does exactly that. Building
 * the masking in here instead would make every other lock pay for it.
 *
 * An earlier version of this comment said that case did not exist,
 * because the ring had one producer and one consumer and both were on
 * the boot cpu. Running procs on the other cpus ended that: uart_poll
 * fills the ring from run_proc, and console_getchar drains it from the
 * cons proc, and neither is pinned anywhere.
 */

#include <stdatomic.h>

#include "kstat.h"

#ifndef NCPU
#define NCPU 1
#endif

/* Only the spin below reaches it, so a uniprocessor build needs no
 * machine at all -- which is what lets luaheap.c's host bench and unit
 * test link this without a platform.
 */
#if NCPU > 1
#include "machine.h"
#endif

static inline void
lock_bump(atomic_ullong *c, unsigned long long by)
{
	atomic_store_explicit(c, atomic_load_explicit(c, memory_order_relaxed) +
	    by, memory_order_relaxed);
}

#if NCPU > 1

/* one writer at a time -- the holder is alone -- but sys.stats() reads
 * these from another cpu holding nothing. Atomic for that reader, never
 * read-modify-written, so the holder pays a relaxed load and store:
 * plain instructions here. Only the waiting is timed; reading the cycle
 * counter on every take would measure the measurement. */
struct lock {
	atomic_uint next;	/* the ticket the next arrival takes */
	atomic_uint owner;	/* the ticket being served */
	atomic_int held;	/* for holding(); see the uniprocessor half */
	atomic_ullong nlock;	/* acquisitions */
	atomic_ullong ncontend;	/* of those, ones that had to wait */
	atomic_ullong spin;	/* cycles spent waiting */
};

#define LOCK_INIT { 0, 0, 0, 0, 0, 0 }

static inline void
lock(struct lock *l)
{
	unsigned t = atomic_fetch_add_explicit(&l->next, 1,
	    memory_order_relaxed);

	unsigned long long t0 = 0;

	if (atomic_load_explicit(&l->owner, memory_order_acquire) != t) {
		t0 = machine_cycles();
		do
			machine_relax();
		while (atomic_load_explicit(&l->owner,
		    memory_order_acquire) != t);
	}
	atomic_store_explicit(&l->held, 1, memory_order_relaxed);
	lock_bump(&l->nlock, 1);
	if (t0) {
		lock_bump(&l->ncontend, 1);
		lock_bump(&l->spin, machine_cycles() - t0);
	}
}

static inline void
unlock(struct lock *l)
{
	unsigned t = atomic_load_explicit(&l->owner, memory_order_relaxed);

	atomic_store_explicit(&l->held, 0, memory_order_relaxed);
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

	if (!atomic_compare_exchange_strong_explicit(&l->next, &n, t + 1,
	    memory_order_acquire, memory_order_relaxed))
		return 0;
	atomic_store_explicit(&l->held, 1, memory_order_relaxed);
	lock_bump(&l->nlock, 1);
	return 1;
}

/* is this lock held at all? Used only by assertions, and deliberately
 * not "held by me": tracking an owner would need a cpu identity in
 * here and lock.h is meant to stay below that. Every caller that
 * asserts is on a path where the only way the lock is held is by
 * itself, so the weaker question answers the same bug.
 */
static inline int
holding(struct lock *l)
{
	return atomic_load_explicit(&l->held, memory_order_relaxed);
}

#else	/* NCPU == 1 */

/* the uniprocessor half is not a no-op, and held is why.
 *
 * A cpu that cannot contend still has a locking *contract*: the inner
 * helpers in kernel.c require the caller to hold the ipc lock, and a
 * caller that forgot is a bug on one cpu too -- it is simply a bug
 * that cannot yet bite. Keeping the flag means the assertions are live
 * on efi, aarch64 and riscv64, which run the same kernel.c and are
 * where a violation would otherwise go unseen until someone built for
 * microvm.
 */
struct lock {
	atomic_int held;
	atomic_ullong nlock;		/* acquisitions */
	atomic_ullong ncontend;		/* always zero: one cpu cannot wait */
	atomic_ullong spin;		/* always zero, for the same reason */
};

#define LOCK_INIT { 0, 0, 0, 0 }

#define barrier() __asm__ volatile ("" ::: "memory")

static inline void
lock(struct lock *l)
{
	barrier();
	atomic_store_explicit(&l->held, 1, memory_order_relaxed);
	lock_bump(&l->nlock, 1);
}

static inline void
unlock(struct lock *l)
{
	atomic_store_explicit(&l->held, 0, memory_order_relaxed);
	barrier();
}

static inline int
canlock(struct lock *l)
{
	lock(l);
	return 1;
}

static inline int
holding(struct lock *l)
{
	return atomic_load_explicit(&l->held, memory_order_relaxed);
}

#endif

#endif
