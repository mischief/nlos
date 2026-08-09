#include <time.h>
#include "platform.h"

extern unsigned long long platform_ticks(void);
extern long long kernel_walltime(void);

/* the machine's wall clock, 0 until something sets it. Nothing here
 * has a battery, so 0 is the honest answer rather than a guess.
 */
time_t
time(time_t *t)
{
	time_t v = (time_t)kernel_walltime();

	if (t)
		*t = v;
	return v;
}

/* monotonic since boot, which is what a clock() caller wants. */
clock_t
clock(void)
{
	return (clock_t)platform_ticks();
}
