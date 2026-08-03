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
#define REG_LVT_TIMER	0x320

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

/* who a message-signalled interrupt should be addressed to. One cpu
 * runs here, so this is always the boot processor's id -- but it is
 * read rather than assumed to be 0, since nothing guarantees that and
 * an MSI aimed at an id no cpu has is delivered to no one.
 */
unsigned
lapic_id(void)
{
	return lapic_read(REG_ID) >> 24;
}
