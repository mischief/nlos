/* the legacy 8253/8254 timer, for machines with no LAPIC.
 *
 * The LAPIC path runs its timer in TSC-deadline mode and re-arms from
 * its own ISR (lapic.c). Neither half of that exists under OpenBSD
 * vmm -- no local APIC, and CPUIDECX_DEADLINE is masked out of guest
 * cpuid -- so the tick comes from vmd's emulated i8253 on irq 0
 * (usr.sbin/vmd/i8253.c) instead. Mode 2 is a rate generator: program
 * the divisor once and it asserts irq 0 forever, which is exactly the
 * periodic tick the scheduler wants and needs no re-arming.
 *
 * The counter is fed by the ancient 1.193182MHz dividing of the
 * 14.31818MHz colour burst crystal, which every PC and every emulation
 * of one still uses.
 */

#include <stdint.h>

#include "microvm.h"

#define PIT_CH0  0x40
#define PIT_MODE 0x43

#define PIT_HZ 1193182UL

/* channel 0, access lobyte then hibyte, mode 2, binary */
#define MODE_RATE_BINARY 0x34

/* the divisor is 16 bits, so anything slower than ~18.2Hz cannot be
 * expressed; 0 means 65536, the slowest the hardware has.
 */
#define DIVISOR_MAX 65536UL

static inline void
outb(uint16_t port, uint8_t v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

/* period_100ns: EFI SetTimer's own unit, the same one
 * lapic_timer_arm_periodic takes, so intr.c can hand either of them
 * the value untouched.
 */
void
pit_arm_periodic(unsigned long long period_100ns)
{
	unsigned long long divisor;

	if (period_100ns == 0)
		period_100ns = 1;

	/* ticks of a 1.193182MHz counter per 100ns period: hz * t / 1e7 */
	divisor = (PIT_HZ * period_100ns) / 10000000ULL;

	if (divisor == 0)
		divisor = 1;		/* faster than the counter can go */
	if (divisor >= DIVISOR_MAX)
		divisor = 0;		/* the encoding for 65536 */

	outb(PIT_MODE, MODE_RATE_BINARY);
	outb(PIT_CH0, (uint8_t)(divisor & 0xff));
	outb(PIT_CH0, (uint8_t)((divisor >> 8) & 0xff));
}
