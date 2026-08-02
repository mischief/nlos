/* the legacy 8259 pair, for machines with no APIC.
 *
 * qemu's microvm has no PIC at all (our launchers say pic=off) and does
 * have an IOAPIC, so nothing here ever runs there. OpenBSD vmm is the
 * other way round: it clears CPUID_APIC, X2APIC and DEADLINE out of
 * guest cpuid (sys/arch/amd64/include/vmmvar.h), so a guest has no
 * local APIC to program and no IOAPIC to route through, and vmd
 * emulates i8259.c and i8253.c instead. intr.c picks between the two at
 * runtime off the cpuid bit; see there for why that is the probe.
 *
 * Vectors are base + irq, with the base chosen so that irq 0 (the PIT)
 * lands on the same vector the LAPIC timer uses on the other path --
 * one timer stub, one timer vector, whichever machine we are on.
 */

#include <stdint.h>

#include "microvm.h"

#define PIC1      0x20		/* master: command 0x20, data 0x21 */
#define PIC2      0xa0		/* slave: command 0xa0, data 0xa1 */
#define PIC1_DATA (PIC1 + 1)
#define PIC2_DATA (PIC2 + 1)

#define ICW1_INIT 0x11		/* cascade, edge triggered, ICW4 follows */
#define ICW4_8086 0x01

#define OCW2_EOI  0x20		/* non-specific end of interrupt */

static inline void
outb(uint16_t port, uint8_t v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

static inline uint8_t
inb(uint16_t port)
{
	uint8_t v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

/* an io delay between the ICW writes. The 8259 is old enough to want
 * settling time between command bytes, and a port write to the unused
 * 0x80 is the traditional way to spend it. On an emulated PIC this is
 * superstition, but it costs one instruction and the day it runs on
 * something real it is not superstition.
 */
static inline void
iowait(void)
{
	outb(0x80, 0);
}

void
pic_init(void)
{
	outb(PIC1, ICW1_INIT);
	iowait();
	outb(PIC2, ICW1_INIT);
	iowait();

	outb(PIC1_DATA, INTR_VECTOR_BASE);		/* irq 0-7 */
	iowait();
	outb(PIC2_DATA, INTR_VECTOR_BASE + 8);		/* irq 8-15 */
	iowait();

	outb(PIC1_DATA, 0x04);	/* slave is on the master's irq 2 */
	iowait();
	outb(PIC2_DATA, 0x02);	/* and it is told that it is */
	iowait();

	outb(PIC1_DATA, ICW4_8086);
	iowait();
	outb(PIC2_DATA, ICW4_8086);
	iowait();

	/* everything masked, like ioapic_init does for the same reason:
	 * whatever ran before us left the redirection state unspecified,
	 * and an unmasked line pointing at a vector we have not claimed
	 * would fire into the fatal trap handler.
	 */
	outb(PIC1_DATA, 0xff);
	outb(PIC2_DATA, 0xff);
}

void
pic_unmask(int irq)
{
	uint16_t port;

	if (irq < 0 || irq > 15)
		return;
	if (irq < 8) {
		port = PIC1_DATA;
	} else {
		port = PIC2_DATA;
		irq -= 8;
		/* the cascade line itself has to be open or nothing on the
		 * slave reaches the cpu, however unmasked it is.
		 */
		outb(PIC1_DATA, inb(PIC1_DATA) & (uint8_t)~(1u << 2));
	}
	outb(port, inb(port) & (uint8_t)~(1u << irq));
}

void
pic_mask(int irq)
{
	uint16_t port;

	if (irq < 0 || irq > 15)
		return;
	if (irq < 8) {
		port = PIC1_DATA;
	} else {
		port = PIC2_DATA;
		irq -= 8;
	}
	outb(port, inb(port) | (uint8_t)(1u << irq));
}

/* the slave does not reach the cpu on its own: an irq above 7 was
 * delivered through the master's cascade line, so both halves are
 * waiting to be told it is over.
 */
void
pic_eoi(int irq)
{
	if (irq >= 8)
		outb(PIC2, OCW2_EOI);
	outb(PIC1, OCW2_EOI);
}
