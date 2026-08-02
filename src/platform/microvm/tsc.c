/* TSC frequency, without ACPI or HPET to calibrate against. Three
 * sources are tried, in this order:
 *
 * 0x15, the TSC/core-crystal ratio, which gives the frequency exactly
 * when the crystal frequency is reported: hz = crystal * num / denom.
 * OpenBSD vmm synthesises this leaf for a guest whenever the host TSC
 * is invariant (sys/arch/amd64/amd64/vmm_machdep.c), so it is the one
 * that answers there, and it is exact rather than measured.
 *
 * the i8254, counted against the TSC for 10ms. This is the only source
 * here that measures rather than asks, so it is the only one that
 * cannot be wrong about a machine that declines to describe itself.
 *
 * 0x16, the processor base frequency in MHz, which is what qemu's
 * -cpu max/host exposes. It ranks below a real measurement because it
 * reports the base frequency rather than the TSC frequency: the two
 * agree on most parts, but only incidentally. vmm passes this leaf
 * straight through from the host, and on AMD the host reports zero.
 *
 * Ordering them this way took a bug that hid for a while. On an AMD
 * host under qemu/KVM all three cpuid answers are absent -- 0x15 is an
 * Intel leaf, 0x16 reports zero, and KVM's paravirt 0x40000010 reads
 * back zero even though the KVMKVMKVM signature is there -- so a guest
 * ran on the 1GHz default below against a real ~4.95GHz TSC. Every
 * timeout in the system then fired at about a fifth of its stated
 * length: a ping given a 3000ms deadline really had 600ms, and the
 * microvm-ping test failed most runs for no reason visible from inside.
 *
 * That invisibility is the point, and the reason the fallback is now
 * reported as loudly as it is. A clock wrong by a constant factor
 * cannot be detected by anything that measures itself -- sleep(3000)
 * still reports 3003ms elapsed, because the sleep and the clock share
 * the constant -- so it can only be caught against a reference outside
 * the guest, or not at all.
 *
 * Any of the three is an independent anchor good enough to derive every
 * busy-wait and the LAPIC TSC-deadline timer from, with no
 * chicken-and-egg stall-to-calibrate-a-stall problem: cpuid needs no
 * clock, and the i8254 is the clock.
 */

#include <stdint.h>

#include "microvm.h"

static unsigned long long hz = 1000000000ULL;	/* 1GHz: only if nothing answers */
static const char *source = "default, UNCALIBRATED";

static inline void
cpuid(uint32_t leaf, uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d)
{
	__asm__ volatile ("cpuid"
	    : "=a" (*a), "=b" (*b), "=c" (*c), "=d" (*d)
	    : "a" (leaf), "c" (0));
}

static inline unsigned long long
rdtsc(void)
{
	unsigned int lo, hi;

	__asm__ volatile ("rdtsc" : "=a" (lo), "=d" (hi));
	return ((unsigned long long)hi << 32) | lo;
}

static inline void
outb(unsigned short port, unsigned char v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

static inline unsigned char
inb(unsigned short port)
{
	unsigned char v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

#define PIT_CH0		0x40
#define PIT_MODE	0x43
#define PIT_HZ		1193182UL

/* how long to count for, and how long to wait before concluding there is
 * no i8254 behind the port at all. The bail-out is in TSC cycles because
 * the whole point here is that we do not yet know what a second is: at
 * any plausible frequency 2e9 cycles is under two seconds, and it is
 * only ever reached on a machine with no PIT, which our own launchers
 * avoid by passing pit=on.
 */
#define CAL_TICKS	11932			/* ~10ms at PIT_HZ */
#define CAL_GIVEUP	2000000000ULL

static uint16_t
pit_read(void)
{
	uint16_t v;

	outb(PIT_MODE, 0x00);			/* latch channel 0 */
	v = inb(PIT_CH0);
	v |= (uint16_t)inb(PIT_CH0) << 8;
	return v;
}

/* Count the i8254 down for CAL_TICKS and see how far the TSC got.
 *
 * Channel 0 in mode 2 free-runs and reloads on its own, so it needs no
 * interrupt: the counter is latched and read over the data port, which
 * means this works on a machine with no PIC and no IOAPIC, and does not
 * touch port 0x61 the way the usual channel-2 gate calibration does.
 * qemu's microvm has none of those three.
 *
 * Ticks are accumulated as wrapped differences rather than compared
 * against an endpoint, so a reload during the run costs nothing as long
 * as we look more often than once per 65536 ticks (54.9ms). Each look
 * is three port accesses, so that holds by a wide margin.
 */
static int
pit_calibrate(void)
{
	unsigned long long t0, t1, cycles;
	uint32_t ticks = 0;
	uint16_t prev, cur;

	/* channel 0, lobyte/hibyte, mode 2, binary; divisor 0 is 65536 */
	outb(PIT_MODE, 0x34);
	outb(PIT_CH0, 0x00);
	outb(PIT_CH0, 0x00);

	prev = pit_read();
	t0 = rdtsc();

	while (ticks < CAL_TICKS) {
		cur = pit_read();
		ticks += (uint16_t)(prev - cur);
		prev = cur;

		if (rdtsc() - t0 > CAL_GIVEUP)
			return 0;		/* nothing is counting */
	}

	t1 = rdtsc();
	cycles = t1 - t0;

	/* refuse an answer that is not a frequency any x86 has run at,
	 * rather than propagating a bad measurement as if it were fact.
	 */
	hz = cycles * PIT_HZ / ticks;
	if (hz < 100000000ULL || hz > 100000000000ULL) {
		hz = 1000000000ULL;
		return 0;
	}

	return 1;
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
			source = "cpuid 0x15 crystal ratio";
			return;
		}
	}

	if (pit_calibrate()) {
		source = "i8254, 10ms";
		return;
	}

	if (max >= 0x16) {
		cpuid(0x16, &a, &b, &c, &d);
		if (a != 0) {
			hz = (unsigned long long)a * 1000000ULL;
			source = "cpuid 0x16 base freq";
			return;
		}
	}
}

unsigned long long
tsc_hz(void)
{
	return hz;
}

const char *
tsc_source(void)
{
	return source;
}

void
platform_stall_us(unsigned long us)
{
	unsigned long long target = rdtsc() + (hz / 1000000ULL) * us;

	while (rdtsc() < target)
		__asm__ volatile ("pause");
}
