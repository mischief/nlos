/* local APIC: fixed MMIO base (microvm has no ACPI/MP tables to
 * discover it from -- 0xFEE00000 is the architectural default every
 * x86 since the P6 uses unless remapped, and qemu/kvm never remaps
 * it). timer runs in TSC-deadline mode, re-armed from its own ISR to
 * fake "periodic": that sidesteps calibrating the classic
 * divide-config/initial-count timer against anything, since we
 * already have an independent cycle-per-second estimate from
 * tsc.c's CPUID-leaf-0x16 read.
 *
 * requires the guest CPU to advertise TSC-deadline (CPUID.01H:ECX.24),
 * which "-cpu max" (what scripts/qemu-microvm.lua asks for) does. A
 * machine without it has no LAPIC either in practice -- OpenBSD vmm
 * masks CPUID_APIC and CPUIDECX_DEADLINE together -- so the fallback
 * is not a different timer here but a different controller entirely:
 * intr.c probes for the APIC and runs i8253.c/i8259.c instead. Nothing
 * in this file executes on such a machine, which is what makes the
 * fixed 0xFEE00000 above safe to keep.
 */

#include <stdint.h>

#include "microvm.h"
#include "platform.h"

#define LAPIC_BASE	0xFEE00000UL

#define REG_ID		0x020
#define REG_EOI		0x0B0
#define REG_SVR		0x0F0
#define REG_ICR_LO	0x300
#define REG_ICR_HI	0x310
#define REG_LVT_TIMER	0x320

/* the interrupt command register, which is how one cpu says anything
 * to another. The high half carries the destination apic id and must
 * be written first; writing the low half is what sends.
 */
#define ICR_INIT	0x00500		/* delivery mode 101 */
#define ICR_STARTUP	0x00600		/* delivery mode 110 */
#define ICR_ASSERT	0x04000
#define ICR_LEVEL	0x08000
#define ICR_DELIVS	0x01000		/* read-only: still dispatching */

#define SVR_ENABLE	0x100

#define LVT_MASKED	0x10000
#define LVT_TSC_DEADLINE 0x40000	/* delivery mode bits 17:18 = 10b */

#define TIMER_VECTOR	0x40

static volatile uint32_t *const lapic = (volatile uint32_t *)LAPIC_BASE;

static unsigned long long period_cycles;

static inline unsigned long long
rdtsc(void)
{
	unsigned int lo, hi;

	__asm__ volatile ("rdtsc" : "=a" (lo), "=d" (hi));
	return ((unsigned long long)hi << 32) | lo;
}

static inline void
wrmsr(uint32_t msr, unsigned long long v)
{
	uint32_t lo = (uint32_t)v, hi = (uint32_t)(v >> 32);

	__asm__ volatile ("wrmsr" : : "c" (msr), "a" (lo), "d" (hi));
}

#define IA32_TSC_DEADLINE 0x6E0

static inline void
lapic_write(unsigned reg, uint32_t v)
{
	lapic[reg / 4] = v;
}

static inline uint32_t
lapic_read(unsigned reg)
{
	return lapic[reg / 4];
}

void
lapic_init(void)
{
	idt_set_vector(TIMER_VECTOR, isr_timer);
	lapic_write(REG_SVR, SVR_ENABLE | 0xFF);	/* spurious vector 0xFF */
	lapic_write(REG_LVT_TIMER, LVT_MASKED | TIMER_VECTOR);
}

/* period_100ns: EFI SetTimer's own unit (100ns ticks), so efi_shim.c
 * can hand it straight through.
 */
void
lapic_timer_arm_periodic(unsigned long long period_100ns)
{
	period_cycles = (tsc_hz() / 10000000ULL) * period_100ns;
	if (period_cycles == 0)
		period_cycles = 1;
	lapic_write(REG_LVT_TIMER, LVT_TSC_DEADLINE | TIMER_VECTOR);
	wrmsr(IA32_TSC_DEADLINE, rdtsc() + period_cycles);
}

/* TSC-deadline is one-shot: a deadline fires once and is done, so
 * "periodic" is this, called from intr.c's timer_isr on every tick.
 * The tick count itself lives there, since its caller must not care
 * which of the two timers this machine has, and the EOI is that
 * function's business for the same reason.
 */
void
lapic_timer_rearm(void)
{
	if (period_cycles)
		wrmsr(IA32_TSC_DEADLINE, rdtsc() + period_cycles);
}

void
lapic_eoi(void)
{
	lapic_write(REG_EOI, 0);
}

/* which cpu is asking. On the boot processor this is also who a
 * message-signalled interrupt should be addressed to: devices stay
 * pointed at the BSP, so an MSI's destination is this and not the id
 * of whichever cpu happened to configure the device.
 *
 * It is read rather than assumed to be 0 because nothing guarantees
 * that, and an MSI aimed at an id no cpu has is delivered to no one.
 */
unsigned
lapic_id(void)
{
	return lapic_read(REG_ID) >> 24;
}

/* wait for the last IPI to be dispatched.
 *
 * The MP spec (B.4) requires this and says why: the APIC neither
 * retries nor guarantees delivery for INIT and STARTUP, so the only
 * evidence a command left is the delivery-status bit going clear. It
 * is bounded because a cpu that will never accept is not a reason to
 * stop booting -- the caller's own timeout is what reports that.
 */
static void
lapic_ipi_wait(void)
{
	for (int i = 0; i < 1000; i++) {
		if ((lapic_read(REG_ICR_LO) & ICR_DELIVS) == 0)
			return;
		platform_stall_us(10);
	}
}

/* the universal start-up algorithm, MP spec appendix B.4, example
 * B-1: INIT, wait, then two STARTUPs carrying the page the target is
 * to begin executing at.
 *
 * The second STARTUP is not belt and braces. A STARTUP may be issued
 * only once after a reset or an INIT, so if the first one is accepted
 * the second is ignored -- and if the first was lost, the second is
 * the one that works. Sending exactly two is what the algorithm says
 * and is cheaper than deciding which case happened.
 *
 * The INIT is asserted and then deasserted, both at level. qemu comes
 * up without the deassert, which is how it went in first -- but a
 * level-triggered assert with no matching deassert is a cpu held in
 * reset on hardware that takes the level seriously, and this is meant
 * to run on some of that eventually. plan9front's lapicstartap sends
 * both; two register writes is not a thing to be clever about.
 */
void
lapic_startap(unsigned apicid, unsigned long entry)
{
	unsigned hi = apicid << 24;

	lapic_write(REG_ICR_HI, hi);
	lapic_write(REG_ICR_LO, ICR_INIT | ICR_LEVEL | ICR_ASSERT);
	lapic_ipi_wait();

	lapic_write(REG_ICR_HI, hi);
	lapic_write(REG_ICR_LO, ICR_INIT | ICR_LEVEL);
	lapic_ipi_wait();

	platform_stall_us(10000);	/* the spec's 10ms */

	for (int i = 0; i < 2; i++) {
		lapic_write(REG_ICR_HI, hi);
		lapic_write(REG_ICR_LO, ICR_STARTUP | (entry >> 12));
		lapic_ipi_wait();
		platform_stall_us(200);
	}
}
