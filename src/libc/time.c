#include <time.h>
#include "platform.h"

/* TODO: wire to EFI GetTime / a real tick source.
 * good enough to feed lua's random seed for now.
 */

extern unsigned long long platform_ticks(void);

time_t
time(time_t *t)
{
	time_t v = (time_t)platform_ticks();

	if (t)
		*t = v;
	return v;
}

clock_t
clock(void)
{
	return (clock_t)platform_ticks();
}
