/* IOAPIC: route a device's wire interrupt to a cpu vector.
 *
 * The LAPIC timer needed none of this -- it is local to the cpu and
 * delivers through its own LVT register. A virtio-mmio device instead
 * asserts a line into the IOAPIC, which has to be told what vector to
 * raise and which cpu to raise it on. Without that the line is asserted
 * and nothing happens, which is why every driver here polled.
 *
 * qemu's microvm wires the eight virtio-mmio slots to consecutive GSIs
 * starting at 5 (see hw/i386/microvm.c, VIRTIO_MMIO_IRQ_BASE), matching
 * the fixed slot scan in virtio.c. The machine is created with
 * ioapic2=off by our launchers precisely so that layout holds.
 */

#include <stdint.h>

#include "microvm.h"

#define IOAPIC_BASE 0xfec00000UL

/* the IOAPIC is addressed indirectly: write a register number to the
 * window at +0x00, then read or write its value at +0x10.
 */
#define IOREGSEL 0x00
#define IOWIN    0x10

#define REG_ID      0x00
#define REG_VER     0x01
#define REG_REDTBL  0x10	/* two 32-bit halves per entry */

/* redirection entry, low half */
#define RED_MASKED       (1u << 16)
#define RED_LEVEL        (1u << 15)	/* trigger mode: 1 = level */
#define RED_ACTIVE_LOW   (1u << 13)
#define RED_LOGICAL      (1u << 11)	/* destination mode */

static volatile uint32_t *ioapic = (volatile uint32_t *)IOAPIC_BASE;

static uint32_t
ioapic_read(unsigned reg)
{
	ioapic[IOREGSEL / 4] = reg;
	return ioapic[IOWIN / 4];
}

static void
ioapic_write(unsigned reg, uint32_t val)
{
	ioapic[IOREGSEL / 4] = reg;
	ioapic[IOWIN / 4] = val;
}

int
ioapic_pins(void)
{
	/* version register bits 23:16 hold the highest entry index */
	return (int)((ioapic_read(REG_VER) >> 16) & 0xff) + 1;
}

void
ioapic_init(void)
{
	int n = ioapic_pins();

	/* mask everything. The firmware that ran before us is qboot, which
	 * leaves entries in an unspecified state, and an unmasked line
	 * pointing at a vector we have not claimed would fire into the
	 * fatal trap handler.
	 */
	for (int i = 0; i < n; i++) {
		ioapic_write(REG_REDTBL + 2 * i, RED_MASKED);
		ioapic_write(REG_REDTBL + 2 * i + 1, 0);
	}
}

/* route gsi to `vector` on the bootstrap cpu, and unmask it.
 *
 * Level-triggered and active-high, which is what virtio-mmio asserts.
 * Level rather than edge matters: the device holds the line up until
 * the driver acknowledges it through the device's own interrupt-ack
 * register, so an edge-triggered entry would see one transition and
 * then miss every later one.
 */
void
ioapic_route(int gsi, int vector)
{
	if (gsi < 0 || gsi >= ioapic_pins())
		return;

	/* high half is the destination: physical mode, apic id 0 */
	ioapic_write(REG_REDTBL + 2 * gsi + 1, 0);
	ioapic_write(REG_REDTBL + 2 * gsi,
	    RED_LEVEL | (uint32_t)(vector & 0xff));
}

void
ioapic_mask(int gsi)
{
	if (gsi < 0 || gsi >= ioapic_pins())
		return;

	uint32_t lo = ioapic_read(REG_REDTBL + 2 * gsi);

	ioapic_write(REG_REDTBL + 2 * gsi, lo | RED_MASKED);
}
