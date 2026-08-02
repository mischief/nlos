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
#define CFG_HEADER   0x0c	/* header type in bits 23:16 */
#define CFG_BAR0     0x10
#define CFG_INTLINE  0x3c	/* irq line (low byte) */

#define COMMAND_IO     0x0001
#define COMMAND_MASTER 0x0004

#define BAR_IS_IO   0x1
#define BAR_IO_MASK 0xfffffffcUL

#define HEADER_MULTIFUNCTION 0x80

/* bus 0 only, and no bridges walked.
 *
 * Every machine this runs on puts its virtio devices directly on bus 0
 * -- vmd's pci.c does not emulate a bridge at all -- so recursing
 * behind one would be code with nothing to find. A machine that does
 * have bridges will need the walk; it will also need much else.
 */
int
pci_find(uint16_t vendor, uint16_t device, struct pci_dev *out)
{
	if (!pci_present())
		return -1;

	for (int dev = 0; dev < 32; dev++) {
		int nfn = 1;

		for (int fn = 0; fn < nfn; fn++) {
			uint32_t id = pci_config_read(0, dev, fn, CFG_ID);

			if (fn == 0) {
				uint32_t hdr = pci_config_read(0, dev, 0,
				    CFG_HEADER);

				if ((hdr >> 16) & HEADER_MULTIFUNCTION)
					nfn = 8;
			}

			if ((id & 0xffff) != vendor)
				continue;
			if (((id >> 16) & 0xffff) != device)
				continue;

			uint32_t bar = pci_config_read(0, dev, fn, CFG_BAR0);
			uint32_t line = pci_config_read(0, dev, fn, CFG_INTLINE);

			out->bus = 0;
			out->dev = dev;
			out->fn = fn;
			out->iobase = (bar & BAR_IS_IO) ?
			    (uint16_t)(bar & BAR_IO_MASK) : 0;
			out->irq = (int)(line & 0xff);

			/* the BAR is useless until the device is told to
			 * decode it. Firmware normally does this; there is
			 * no firmware here, and vmd leaves the command
			 * register at whatever it was.
			 */
			uint32_t cmd = pci_config_read(0, dev, fn,
			    CFG_COMMAND);

			pci_config_write(0, dev, fn, CFG_COMMAND,
			    cmd | COMMAND_IO | COMMAND_MASTER);
			return 0;
		}
	}
	return -1;
}
