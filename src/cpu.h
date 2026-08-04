#ifndef CPU_H
#define CPU_H

/* one of these per cpu, and where everything that used to be a bare
 * static in kernel.c ends up.
 *
 * Arch-blind, because kernel.c is. How a cpu finds its own struct is
 * the platform's business -- cpu_self() is implemented over %gs on
 * microvm and as "the only one" on efi -- and nothing above this line
 * needs to know which.
 */

#include <sys/queue.h>

#include "lock.h"

struct kproc;

/* dispatch keeps two of these per cpu and swaps them each lap: one
 * holds procs still to run, the other those that have run. membership
 * is what says "already had its turn", so there is no per-lap array to
 * size against MAXPROCS and nothing to scan.
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

struct cpu {
	/* first, and at offset 0, because cpu_self() on x86_64 reads it
	 * through %gs and the offset is written into the asm.
	 */
	struct cpu *self;

	unsigned idx;			/* 0 is the boot processor, always */
	unsigned apicid;		/* what the hardware calls it */

	/* the run queues, and the lock over them. Another cpu takes
	 * this to wake a proc that belongs here, which is the only
	 * cross-cpu scheduler operation there is.
	 */
	struct lock lock;
	struct rqset rq[2];
	struct rqset *runq, *donq;

	/* who is running right now, or null. Read by plain C with no
	 * lua_State to find out who is asking; written by run_proc
	 * either side of every resume.
	 */
	struct kproc *current;

	/* running the dispatch loop, and so able to be given work. The
	 * boot processor sets it in kernel_run; an AP sets it when it
	 * enters its own loop. Placement only considers cpus that have
	 * it, which is what keeps a proc off a cpu that is still parked
	 * in hlt and would never run it.
	 */
	int dispatching;

	/* parked in the platform's idle sleep and needs an interrupt to
	 * come out. Set before sleeping and cleared on waking, so a cpu
	 * queueing work here knows whether to send one.
	 */
	int idle;

	unsigned long long nlaps, ndispatch, nidle;
};

/* this cpu. */
struct cpu *cpu_self(void);

/* cpu i, or null past the end. i < platform_ncpu(). */
struct cpu *cpu_at(unsigned i);

#endif
