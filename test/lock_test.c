/* lock.h on a real multiprocessor: the host's, with pthreads standing
 * in for cpus. Emits TAP.
 *
 * A spinlock cannot be tested from inside the kernel that has only one
 * cpu, and it is the wrong thing to trust to inspection: the failure
 * mode of a wrong memory order is a rare lost update on hardware the
 * test was never run on. So it is tested here, natively, against real
 * cores -- which is the same argument that puts luaheap in this
 * directory.
 *
 * The counter the threads fight over is deliberately not atomic. If it
 * were, mutual exclusion could be broken and the test would still pass.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "machine.h"
#include "lock.h"
#include "tap.h"

/* more threads than the host has cpus is not a stronger test, it is a
 * different one: a ticket lock hands off in fifo order, so a descheduled
 * holder of the next ticket parks every other thread in machine_relax()
 * for a timeslice. The build sets this to the host's cpu count.
 */
#ifndef NTHREAD
#define NTHREAD	8
#endif
#ifndef NITER
#define NITER	20000
#endif

static struct lock l = LOCK_INIT;
static unsigned long shared;		/* not atomic, on purpose */
static unsigned long per[NTHREAD];

/* the start gate. It is atomic and not volatile: volatile stops the
 * compiler caching a load, but it orders nothing between threads, so a
 * plain read of it is a data race. Thread sanitizer reports one.
 *
 * Relaxed is enough. The gate only has to be seen. The lock below
 * orders everything that must be ordered, and it is the thing under
 * test, so the harness must not help it.
 */
static atomic_int go;

static void *
hammer(void *arg)
{
	long id = (long)arg;

	while (!atomic_load_explicit(&go, memory_order_relaxed))
		machine_relax();

	for (int i = 0; i < NITER; i++) {
		lock(&l);
		/* a read-modify-write wide enough to lose a race: two
		 * cpus inside here at once will drop an increment.
		 */
		unsigned long v = shared;
		shared = v + 1;
		per[id]++;
		unlock(&l);
	}
	return 0;
}

static int
test_exclusion(void *arg)
{
	pthread_t th[NTHREAD];

	(void)arg;

	shared = 0;
	memset(per, 0, sizeof per);
	atomic_store_explicit(&go, 0, memory_order_relaxed);

	for (long i = 0; i < NTHREAD; i++)
		if (pthread_create(&th[i], 0, hammer, (void *)i) != 0) {
			TAP_CHECK(0, "pthread_create");
			return 1;
		}
	atomic_store_explicit(&go, 1, memory_order_relaxed);
	for (int i = 0; i < NTHREAD; i++)
		pthread_join(th[i], 0);

	TAP_CHECK(shared == (unsigned long)NTHREAD * NITER,
	    "every increment under the lock survives");
	tap_diag("shared=%lu want=%lu", shared, (unsigned long)NTHREAD * NITER);

	/* the ticket lock's reason for being: no cpu is passed over.
	 * A test-and-set would pass the count above and can fail this.
	 */
	int fair = 1;
	for (int i = 0; i < NTHREAD; i++)
		if (per[i] != NITER)
			fair = 0;
	TAP_CHECK(fair, "every thread completed its iterations");
	return 0;
}

static int
test_canlock(void *arg)
{
	struct lock t = LOCK_INIT;

	(void)arg;

	TAP_CHECK(canlock(&t), "canlock takes a free lock");
	TAP_CHECK(!canlock(&t), "canlock refuses a held lock");
	unlock(&t);
	TAP_CHECK(canlock(&t), "canlock takes it again once released");
	unlock(&t);

	lock(&t);
	TAP_CHECK(!canlock(&t), "canlock refuses one held by lock()");
	unlock(&t);
	return 0;
}

/* the ordering property, which is the half a counter cannot see: a
 * value published before unlock is visible to whoever takes the lock
 * next. Under a release/acquire pair this holds; with relaxed on
 * either side it is free to break on a weakly ordered machine.
 */
static struct lock hl = LOCK_INIT;
static unsigned long payload[16];
static unsigned long seen_bad;

static void *
handoff(void *arg)
{
	long id = (long)arg;

	while (!atomic_load_explicit(&go, memory_order_relaxed))
		machine_relax();

	for (int i = 0; i < NITER; i++) {
		lock(&hl);
		for (int k = 0; k < 16; k++)
			if (payload[k] != payload[0])
				seen_bad++;
		for (int k = 0; k < 16; k++)
			payload[k] = (unsigned long)id * NITER + i;
		unlock(&hl);
	}
	return 0;
}

static int
test_handoff(void *arg)
{
	pthread_t th[NTHREAD];

	(void)arg;

	memset(payload, 0, sizeof payload);
	seen_bad = 0;
	atomic_store_explicit(&go, 0, memory_order_relaxed);

	for (long i = 0; i < NTHREAD; i++)
		if (pthread_create(&th[i], 0, handoff, (void *)i) != 0) {
			TAP_CHECK(0, "pthread_create");
			return 1;
		}
	atomic_store_explicit(&go, 1, memory_order_relaxed);
	for (int i = 0; i < NTHREAD; i++)
		pthread_join(th[i], 0);

	TAP_CHECK(seen_bad == 0, "a write published before unlock is whole after lock");
	tap_diag("torn observations: %lu", seen_bad);
	return 0;
}

int
main(void)
{
	tap_diag("NCPU=%d, %d threads x %d iterations", NCPU, NTHREAD, NITER);
	if (NCPU == 1)
		tap_diag("uniprocessor build: lock() is a compiler barrier and "
		    "the concurrent cases prove nothing");

	TAP_ADD("canlock", test_canlock, NULL);
	TAP_ADD("exclusion", test_exclusion, NULL);
	TAP_ADD("handoff", test_handoff, NULL);
	return tap_run();
}
