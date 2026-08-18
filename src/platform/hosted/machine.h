#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives lock.h needs, on a machine that is a process.
 * Written against the host rather than against any instruction set, so
 * this platform builds wherever the libc does.
 */

#include <sched.h>
#include <time.h>

/* the host schedules this thread, so the useful thing to do while
 * waiting is give the cpu back rather than spin on it.
 */
static inline void
machine_relax(void)
{
	sched_yield();
}

/* nanoseconds, the same unit and source as platform_ticks. */
static inline unsigned long long
machine_cycles(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ULL +
	    (unsigned long long)ts.tv_nsec;
}

/* one cpu here, so nothing calls these: cpu_self() in main.c is the
 * single static, and lock.h takes its uniprocessor path.
 */
static inline void *
machine_cpu_self(void)
{
	return 0;
}

static inline void
machine_set_cpu_self(void *p)
{
	(void)p;
}

#endif
