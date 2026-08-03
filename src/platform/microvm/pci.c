/* is there a PCI bus here? -- the second of the two runtime probes this
 * platform makes about its machine (intr.c has the other).
 *
 * qemu's microvm has no PCI at all: virtio devices sit in a fixed
 * window of eight mmio slots at 0xfeb00000, and virtio.c finds them by
 * reading the magic value out of each. OpenBSD vmd is the opposite --
 * its virtio devices are PCI (usr.sbin/vmd/virtio.c attaches them with
 * pci_add_device) and there is no mmio window.
 *
 * The window cannot be probed by reading it. 0xfeb00000 falls inside
 * the PCI MMIO range vmd declares as VM_MEM_MMIO, and a read of an
 * address no emulated device claims terminates the guest -- silently,
 * with nothing in vmd's log. That is not a fault our IDT ever sees, so
 * there is no way to try it and recover. It has to be decided in
 * advance, and this is the proxy: a machine with a PCI host bridge is
 * not qemu's microvm, so its 0xfeb00000 is not ours to touch.
 *
 * The mechanism is the ancient one: write a bus/dev/fn/reg address to
 * 0xcf8, read the value at 0xcfc. Nothing answers on a machine without
 * a host bridge, and the read comes back all-ones.
 */

#include <stdint.h>

#include "microvm.h"

#define PCI_CONFIG_ADDR 0xcf8
#define PCI_CONFIG_DATA 0xcfc

#define CONFIG_ENABLE 0x80000000UL

static inline void
outl(uint16_t port, uint32_t v)
{
	__asm__ volatile ("outl %0, %1" : : "a" (v), "Nd" (port));
}

static inline uint32_t
inl(uint16_t port)
{
	uint32_t v;

	__asm__ volatile ("inl %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static uint32_t
cfg_addr(int bus, int dev, int fn, int reg)
{
	return CONFIG_ENABLE |
	    ((uint32_t)bus << 16) | ((uint32_t)(dev & 0x1f) << 11) |
	    ((uint32_t)(fn & 7) << 8) | (uint32_t)(reg & 0xfc);
}

uint32_t
pci_config_read(int bus, int dev, int fn, int reg)
{
	outl(PCI_CONFIG_ADDR, cfg_addr(bus, dev, fn, reg));
	return inl(PCI_CONFIG_DATA);
}

void
pci_config_write(int bus, int dev, int fn, int reg, uint32_t v)
{
	outl(PCI_CONFIG_ADDR, cfg_addr(bus, dev, fn, reg));
	outl(PCI_CONFIG_DATA, v);
}

/* 00:00.0's vendor id. A real host bridge answers with its own; an
 * absent bus leaves the data port floating, which every emulation and
 * every real chipset reports as 0xffff.
 */
int
pci_present(void)
{
	static int probed, present;

	if (!probed) {
		uint32_t id = pci_config_read(0, 0, 0, 0);
		uint16_t vendor = (uint16_t)(id & 0xffff);

		present = (vendor != 0xffff && vendor != 0x0000);
		probed = 1;
	}
	return present;
}

/* config space offsets, the ones this needs and no more */
#define CFG_ID       0x00	/* vendor (low) and device (high) */
#define CFG_COMMAND  0x04
#define CFG_STATUS   0x04	/* status is the high half of the same word */
#define CFG_HEADER   0x0c	/* header type in bits 23:16 */
#define CFG_BAR0     0x10
#define CFG_SECBUS   0x18	/* bridges: secondary bus in bits 15:8 */
#define CFG_CAP_PTR  0x34
#define CFG_INTLINE  0x3c	/* irq line (low byte) */

#define COMMAND_IO     0x0001
#define COMMAND_MEMORY 0x0002
#define COMMAND_MASTER 0x0004

#define STATUS_CAP_LIST (1u << 20)	/* bit 4 of the status half */

#define BAR_IS_IO     0x1
#define BAR_IO_MASK   0xfffffffcUL
#define BAR_MEM_MASK  0xfffffff0UL
#define BAR_MEM_TYPE  0x6		/* bits 2:1: 0 = 32-bit, 2 = 64-bit */
#define BAR_MEM_64    0x4

#define HEADER_TYPE_MASK     0x7f
#define HEADER_TYPE_BRIDGE   0x01
#define HEADER_MULTIFUNCTION 0x80

/* every BAR the device implements, in the address space it asks for.
 *
 * A 64-bit memory BAR occupies two registers, so the array index is the
 * register index and the upper half's slot is left empty rather than
 * renumbered -- the virtio capability list names BARs by register
 * index, and renumbering would silently point it at the wrong one.
 *
 * Whoever assigned these addresses is not our concern: firmware does it
 * on a machine that has firmware, and vmd hardcodes them. Nothing here
 * sizes or places a BAR, which is the one thing a machine with neither
 * would need.
 */
static void
read_bars(int bus, int dev, int fn, struct pci_dev *out)
{
	for (int i = 0; i < PCI_NUM_BARS; i++) {
		uint32_t v = pci_config_read(bus, dev, fn, CFG_BAR0 + i * 4);

		if (v == 0)
			continue;

		if (v & BAR_IS_IO) {
			out->bar[i].is_io = 1;
			out->bar[i].base = v & BAR_IO_MASK;
			continue;
		}

		out->bar[i].base = v & BAR_MEM_MASK;

		if ((v & BAR_MEM_TYPE) == BAR_MEM_64 && i + 1 < PCI_NUM_BARS) {
			uint32_t hi = pci_config_read(bus, dev, fn,
			    CFG_BAR0 + (i + 1) * 4);

			out->bar[i].base |= (uint64_t)hi << 32;
			i++;	/* the upper half is not a BAR of its own */
		}
	}
}

int
pci_cap_find(const struct pci_dev *pd, uint8_t id, int vendor_type)
{
	uint32_t status = pci_config_read(pd->bus, pd->dev, pd->fn, CFG_STATUS);

	if (!(status & STATUS_CAP_LIST))
		return 0;

	unsigned off = pci_config_read(pd->bus, pd->dev, pd->fn,
	    CFG_CAP_PTR) & 0xfc;

	/* a malformed list could loop; the space it walks is 256 bytes and
	 * a capability is at least 4, so this many steps is beyond generous.
	 */
	for (int guard = 0; off >= 0x40 && off < 0x100 && guard < 64; guard++) {
		uint32_t w0 = pci_config_read(pd->bus, pd->dev, pd->fn, off);
		uint8_t this_id = (uint8_t)(w0 & 0xff);
		uint8_t next = (uint8_t)((w0 >> 8) & 0xff);

		if (this_id == id &&
		    (vendor_type < 0 ||
		    (int)((w0 >> 24) & 0xff) == vendor_type))
			return (int)off;

		if (next == 0)
			break;
		off = next & 0xfc;
	}
	return 0;
}

/* claim a device: fill *out and turn on decoding.
 *
 * A BAR is useless until the device is told to answer for it, and
 * whether that has already happened is not something to assume in
 * either direction -- firmware sets these bits, vmd leaves the register
 * as it found it, and a hotplugged device arrives with them clear.
 * Setting all three is idempotent.
 */
static void
claim(int bus, int dev, int fn, struct pci_dev *out)
{
	uint32_t line = pci_config_read(bus, dev, fn, CFG_INTLINE);
	uint32_t cmd = pci_config_read(bus, dev, fn, CFG_COMMAND);

	out->bus = bus;
	out->dev = dev;
	out->fn = fn;
	out->irq = (int)(line & 0xff);
	read_bars(bus, dev, fn, out);

	pci_config_write(bus, dev, fn, CFG_COMMAND,
	    cmd | COMMAND_IO | COMMAND_MEMORY | COMMAND_MASTER);
}

/* the search proper, one bus at a time, descending through bridges.
 *
 * A bridge is followed rather than the bus space being scanned flat,
 * because the secondary bus number is the only thing that says which of
 * the 256 possible buses exist: a PCIe root port that firmware has not
 * numbered reports 0, and following that would restart the scan on bus
 * 0 forever. `depth` bounds the descent for the same reason.
 *
 * This matters on any machine with PCIe root ports -- q35, and every
 * real one -- where a device is not on bus 0 at all. It costs nothing
 * on vmd, whose devices are all on bus 0 and which emulates no bridge.
 */
static int
scan_bus(int bus, int depth, uint16_t vendor, uint16_t device, uint16_t alt,
    struct pci_dev *out)
{
	if (depth > 8)
		return -1;

	for (int dev = 0; dev < 32; dev++) {
		int nfn = 1;

		for (int fn = 0; fn < nfn; fn++) {
			uint32_t id = pci_config_read(bus, dev, fn, CFG_ID);
			uint16_t vid = (uint16_t)(id & 0xffff);
			uint16_t did = (uint16_t)((id >> 16) & 0xffff);

			if (vid == 0xffff || vid == 0x0000)
				continue;

			uint32_t hdr = pci_config_read(bus, dev, fn,
			    CFG_HEADER) >> 16;

			if (fn == 0 && (hdr & HEADER_MULTIFUNCTION))
				nfn = 8;

			if (vid == vendor && (did == device || did == alt)) {
				claim(bus, dev, fn, out);
				return 0;
			}

			if ((hdr & HEADER_TYPE_MASK) != HEADER_TYPE_BRIDGE)
				continue;

			int sec = (int)((pci_config_read(bus, dev, fn,
			    CFG_SECBUS) >> 8) & 0xff);

			if (sec <= bus)
				continue;	/* unnumbered, or backwards */
			if (scan_bus(sec, depth + 1, vendor, device, alt,
			    out) == 0)
				return 0;
		}
	}
	return -1;
}

int
pci_find2(uint16_t vendor, uint16_t device, uint16_t alt, struct pci_dev *out)
{
	if (!pci_present())
		return -1;

	for (int i = 0; i < PCI_NUM_BARS; i++) {
		out->bar[i].base = 0;
		out->bar[i].is_io = 0;
	}
	return scan_bus(0, 0, vendor, device, alt, out);
}

int
pci_find(uint16_t vendor, uint16_t device, struct pci_dev *out)
{
	return pci_find2(vendor, device, 0xffff, out);
}
