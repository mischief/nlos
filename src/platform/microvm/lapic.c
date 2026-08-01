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
 * which "-cpu max" (what scripts/qemu-microvm.sh asks for) does; a
 * cpu model without it would leave the LVT timer permanently masked
 * and this platform has no fallback for that yet.
 */

#include <stdint.h>

#include "microvm.h"
#include "platform.h"

#define LAPIC_BASE	0xFEE00000UL

#define REG_EOI		0x0B0
#define REG_SVR		0x0F0
#define REG_LVT_TIMER	0x320

#define SVR_ENABLE	0x100

#define LVT_MASKED	0x10000
#define LVT_TSC_DEADLINE 0x40000	/* delivery mode bits 17:18 = 10b */

#define TIMER_VECTOR	0x40

static volatile uint32_t *const lapic = (volatile uint32_t *)LAPIC_BASE;

static volatile unsigned long long ticks;
static unsigned long long period_cycles;
static int periodic;

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
	periodic = 1;
	lapic_write(REG_LVT_TIMER, LVT_TSC_DEADLINE | TIMER_VECTOR);
	wrmsr(IA32_TSC_DEADLINE, rdtsc() + period_cycles);
}

unsigned long long
lapic_ticks(void)
{
	return ticks;
}

void
lapic_timer_isr(void)
{
	ticks++;
	if (periodic)
		wrmsr(IA32_TSC_DEADLINE, rdtsc() + period_cycles);
	lapic_eoi();
}

void
lapic_eoi(void)
{
	lapic_write(REG_EOI, 0);
}
