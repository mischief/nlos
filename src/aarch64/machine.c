/* aarch64 machine bits */
#include "platform.h"

/* the virtual counter. like rdtsc it is a free-running tick count at a
 * fixed rate (CNTFRQ_EL0, 62.5MHz under qemu/kvm rather than a GHz), so
 * it is far coarser than a TSC -- which is fine, because nothing here
 * uses raw ticks as a duration: boot calibrates against BS->Stall.
 * deliberately not serialized with an isb; rdtsc is not either, and one
 * tick of skew is far below the resolution anyone reads this at.
 */
unsigned long long
platform_ticks(void)
{
	unsigned long long v;

	__asm__ volatile ("mrs %0, cntvct_el0" : "=r" (v));
	return v;
}

_Noreturn void
machine_halt(void)
{
	for (;;)
		__asm__ volatile ("wfi");
}

const char *
platform_arch(void)
{
	return "aarch64";
}
