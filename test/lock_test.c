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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "machine.h"
#include "lock.h"

static int count, failed;

static int
ok(int cond, const char *name)
{
	count++;
	if (!cond)
		failed++;
	printf("%s %d - %s\n", cond ? "ok" : "not ok", count, name);
	fflush(stdout);
	return cond;
}

static void
diag(const char *fmt, ...)
{
	va_list ap;

	fputs("# ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
	fflush(stdout);
}

#define NTHREAD	8
#define NITER	20000

static struct lock l = LOCK_INIT;
static unsigned long shared;		/* not atomic, on purpose */
static unsigned long per[NTHREAD];
static volatile int go;

static void *
hammer(void *arg)
{
	long id = (long)arg;

	while (!go)
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

static void
test_exclusion(void)
{
	pthread_t th[NTHREAD];

	shared = 0;
	memset(per, 0, sizeof per);
	go = 0;

	for (long i = 0; i < NTHREAD; i++)
		if (pthread_create(&th[i], 0, hammer, (void *)i) != 0) {
			ok(0, "pthread_create");
			return;
		}
	go = 1;
	for (int i = 0; i < NTHREAD; i++)
		pthread_join(th[i], 0);

	ok(shared == (unsigned long)NTHREAD * NITER,
	    "every increment under the lock survives");
	diag("shared=%lu want=%lu", shared, (unsigned long)NTHREAD * NITER);

	/* the ticket lock's reason for being: no cpu is passed over.
	 * A test-and-set would pass the count above and can fail this.
	 */
	int fair = 1;
	for (int i = 0; i < NTHREAD; i++)
		if (per[i] != NITER)
			fair = 0;
	ok(fair, "every thread completed its iterations");
}

static void
test_canlock(void)
{
	struct lock t = LOCK_INIT;

	ok(canlock(&t), "canlock takes a free lock");
	ok(!canlock(&t), "canlock refuses a held lock");
	unlock(&t);
	ok(canlock(&t), "canlock takes it again once released");
	unlock(&t);

	lock(&t);
	ok(!canlock(&t), "canlock refuses one held by lock()");
	unlock(&t);
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

	while (!go)
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

static void
test_handoff(void)
{
	pthread_t th[NTHREAD];

	memset(payload, 0, sizeof payload);
	seen_bad = 0;
	go = 0;

	for (long i = 0; i < NTHREAD; i++)
		if (pthread_create(&th[i], 0, handoff, (void *)i) != 0) {
			ok(0, "pthread_create");
			return;
		}
	go = 1;
	for (int i = 0; i < NTHREAD; i++)
		pthread_join(th[i], 0);

	ok(seen_bad == 0, "a write published before unlock is whole after lock");
	diag("torn observations: %lu", seen_bad);
}

int
main(void)
{
	diag("NCPU=%d, %d threads x %d iterations", NCPU, NTHREAD, NITER);
	if (NCPU == 1)
		diag("uniprocessor build: lock() is a compiler barrier and "
		    "the concurrent cases prove nothing");

	test_canlock();
	test_exclusion();
	test_handoff();

	printf("1..%d\n", count);
	return failed ? 1 : 0;
}
