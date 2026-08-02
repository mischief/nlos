/* TSC frequency, without ACPI/HPET to calibrate against and without
 * assuming a PIT (qemu's microvm has none). Two cpuid leaves are asked,
 * in this order:
 *
 * 0x15, the TSC/core-crystal ratio, which gives the frequency exactly
 * when the crystal frequency is reported: hz = crystal * num / denom.
 * OpenBSD vmm synthesises this leaf for a guest whenever the host TSC
 * is invariant (sys/arch/amd64/amd64/vmm_machdep.c), so it is the one
 * that answers there.
 *
 * 0x16, the processor base frequency in MHz, which is what qemu's
 * -cpu max/host exposes. vmm passes this leaf straight through from
 * the host, and on AMD the host reports zero -- a vmd guest was
 * running on the 1GHz default below until 0x15 was asked first.
 *
 * Either is an independent anchor good enough to derive every busy-wait
 * and the LAPIC TSC-deadline timer from, with no chicken-and-egg
 * stall-to-calibrate-a-stall problem.
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
	uint32_t a, b, c, d, max;

	cpuid(0, &max, &b, &c, &d);

	if (max >= 0x15) {
		/* eax = denominator, ebx = numerator, ecx = crystal hz. Any
		 * of the three may be zero, which means "not enumerated"
		 * rather than zero, so all three have to be there.
		 */
		cpuid(0x15, &a, &b, &c, &d);
		if (a != 0 && b != 0 && c != 0) {
			hz = (unsigned long long)c * b / a;
			return;
		}
	}

	if (max >= 0x16) {
		cpuid(0x16, &a, &b, &c, &d);
		if (a != 0) {
			hz = (unsigned long long)a * 1000000ULL;
			return;
		}
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
