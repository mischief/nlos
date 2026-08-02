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

uint32_t
pci_config_read(int bus, int dev, int fn, int reg)
{
	uint32_t addr = CONFIG_ENABLE |
	    ((uint32_t)bus << 16) | ((uint32_t)(dev & 0x1f) << 11) |
	    ((uint32_t)(fn & 7) << 8) | (uint32_t)(reg & 0xfc);

	outl(PCI_CONFIG_ADDR, addr);
	return inl(PCI_CONFIG_DATA);
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
