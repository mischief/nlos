/* which interrupt controller this machine has, decided at boot, and the
 * seam every driver routes and acknowledges through.
 *
 * There are two machines now. qemu's microvm has a LAPIC and an IOAPIC
 * and no PIC or PIT (our launchers pass pic=off, pit=off). OpenBSD vmd
 * has a PIC and a PIT and no APIC of either kind: vmm masks CPUID_APIC,
 * CPUIDECX_X2APIC and CPUIDECX_DEADLINE out of guest cpuid
 * (sys/arch/amd64/include/vmmvar.h), and 0xFEE00000/0xFEC00000 are
 * unbacked guest-physical memory -- the first write to the IOAPIC
 * terminated the guest, with no output and nothing in vmd's log.
 *
 * The probe is cpuid, not ACPI. Neither machine has usable ACPI tables
 * -- vmd supplies none at all -- so a table walk would answer nothing
 * on the platform that needs the answer most. CPUID.01H:EDX bit 9 is
 * the architectural way to ask "is there a local APIC?", it is one
 * instruction, and it is the actual question.
 *
 * Vector policy, one rule for both paths: vector = INTR_VECTOR_BASE +
 * gsi. That falls out of the 8259, whose vectors are base + irq by
 * construction, and costs the IOAPIC nothing since it can raise any
 * vector for any line. It also ends a collision the old fixed vectors
 * had: the LAPIC timer and every virtio device both claimed 0x40, so on
 * a guest with virtio-net, virtio_irq_enable's idt_set_vector quietly
 * replaced the timer's handler with its own. Now the timer has 0x40 to
 * itself (gsi 0 is the PIT, which no machine here uses while it has a
 * LAPIC) and the virtio slots start at 0x45.
 */

#include <stdint.h>

#include "microvm.h"

/* the tick, owned here rather than by either timer, because
 * timer_ticks()'s caller must not care which one is running.
 */
static volatile unsigned long long ticks;
static int have_apic = -1;	/* -1 until probed */

static inline void
cpuid(uint32_t leaf, uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d)
{
	__asm__ volatile ("cpuid"
	    : "=a" (*a), "=b" (*b), "=c" (*c), "=d" (*d)
	    : "a" (leaf), "c" (0));
}

#define CPUID_EDX_APIC (1u << 9)

int
intr_have_apic(void)
{
	if (have_apic < 0) {
		uint32_t a, b, c, d;

		cpuid(1, &a, &b, &c, &d);
		have_apic = (d & CPUID_EDX_APIC) != 0;
	}
	return have_apic;
}

void
intr_init(void)
{
	if (intr_have_apic()) {
		/* a machine can have both, and one that does arrives here
		 * with the 8259 however the firmware left it -- on q35 that
		 * is SeaBIOS's mapping, irq 0-7 on vectors 0x08-0x0f with
		 * the PIT running, so the first tick after sti is delivered
		 * as vector 8 and read as a double fault. pic_init masks
		 * both halves and moves them off the exception vectors, so
		 * the only controller that can raise anything is the one we
		 * program. On a machine with no PIC (qemu microvm says
		 * pic=off) these are writes to unassigned ports.
		 */
		pic_init();
		ioapic_init();	/* mask every line before enabling anything */
		lapic_init();
	} else {
		pic_init();
	}
}

/* install a handler for a device line and open it.
 *
 * The vector is this layer's business, not the caller's: on the 8259 it
 * is not a free choice, and having one rule for both controllers means
 * a driver names only the line it is wired to.
 */
void
intr_route(int gsi, void (*handler)(void))
{
	int vector = INTR_VECTOR_BASE + gsi;

	idt_set_vector(vector, handler);

	if (intr_have_apic())
		ioapic_route(gsi, vector);
	else
		pic_unmask(gsi);
}

/* the message-signalled path. There is no controller in it: the device
 * writes the vector at the LAPIC itself, so there is nothing to route
 * and nothing to unmask -- only a handler to install, and the LAPIC to
 * tell when it is over.
 *
 * The vectors start above the line-derived ones. INTR_VECTOR_BASE + gsi
 * covers as many vectors as the IOAPIC has pins, and 24 is the widest
 * one on any machine here; starting at 64 leaves that whole range
 * alone with room to spare.
 */
#define MSI_VECTOR_BASE  (INTR_VECTOR_BASE + 64)
#define MSI_VECTOR_COUNT 32

int
intr_alloc_vector(void)
{
	static int next;

	if (next >= MSI_VECTOR_COUNT)
		return -1;
	return MSI_VECTOR_BASE + next++;
}

void
intr_route_msi(int vector, void (*handler)(void))
{
	idt_set_vector(vector, handler);
}

void
intr_eoi_msi(void)
{
	lapic_eoi();
}

void
intr_mask(int gsi)
{
	if (intr_have_apic())
		ioapic_mask(gsi);
	else
		pic_mask(gsi);
}

/* every handler owes this before it returns, or nothing at that
 * priority is delivered again. The LAPIC wants only to be told it
 * happened; the 8259 wants to know which line, and which of its two
 * halves that line was on.
 */
void
intr_eoi(int gsi)
{
	if (intr_have_apic())
		lapic_eoi();
	else
		pic_eoi(gsi);
}

/* ---- the tick ---- */

void
timer_arm_periodic(unsigned long long period_100ns)
{
	if (intr_have_apic()) {
		lapic_timer_arm_periodic(period_100ns);
	} else {
		/* routed on the first arm rather than in intr_init: until
		 * something asks for a tick there is no handler to send it
		 * to, and the same ordering rule the ioapic path follows --
		 * open the line last -- applies here.
		 */
		intr_route(TIMER_GSI, isr_timer);
		pit_arm_periodic(period_100ns);
	}
}

unsigned long long
timer_ticks(void)
{
	return ticks;
}

/* called from isr_timer (idt_stubs.S) on both paths. The LAPIC's
 * TSC-deadline mode is one-shot, so its "periodic" is this re-arm; the
 * PIT in mode 2 free-runs and needs nothing.
 */
void
timer_isr(void)
{
	ticks++;
	if (intr_have_apic())
		lapic_timer_rearm();
	intr_eoi(TIMER_GSI);
}
