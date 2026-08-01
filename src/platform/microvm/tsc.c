/* TSC frequency, without ACPI/PIT/HPET to calibrate against (microvm
 * has none of those). CPUID leaf 0x16 (processor frequency info) gives
 * the base frequency in MHz directly on any CPU qemu's -cpu max/host
 * exposes it for; that's an independent anchor good enough to derive
 * every busy-wait and the LAPIC TSC-deadline timer from, with no
 * chicken-and-egg stall-to-calibrate-a-stall problem.
 */

#include <stdint.h>

#include "microvm.h"

static unsigned long long hz = 1000000000ULL;	/* 1GHz: only if cpuid has nothing */

static inline void
cpuid(uint32_t leaf, uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d)
{
	__asm__ volatile ("cpuid"
	    : "=a" (*a), "=b" (*b), "=c" (*c), "=d" (*d)
	    : "a" (leaf), "c" (0));
}

void
tsc_calibrate(void)
{
	uint32_t a, b, c, d;

	cpuid(0, &a, &b, &c, &d);
	if (a >= 0x16) {
		cpuid(0x16, &a, &b, &c, &d);
		if (a != 0)
			hz = (unsigned long long)a * 1000000ULL;
	}
}

unsigned long long
tsc_hz(void)
{
	return hz;
}

static inline unsigned long long
rdtsc(void)
{
	unsigned int lo, hi;

	__asm__ volatile ("rdtsc" : "=a" (lo), "=d" (hi));
	return ((unsigned long long)hi << 32) | lo;
}

void
platform_stall_us(unsigned long us)
{
	unsigned long long target = rdtsc() + (hz / 1000000ULL) * us;

	while (rdtsc() < target)
		__asm__ volatile ("pause");
}
