/* legacy virtio-PCI: the transport OpenBSD vmd has.
 *
 * Same registers as virtio-mmio in meaning, and the same rings behind
 * them -- QUEUE_PFN really is a page number of one contiguous
 * desc/avail/used allocation, exactly as in legacy mmio -- but reached
 * through an IO BAR at the "Virtio 0.9 config space" offsets
 * (sys/dev/pci/virtio_pcireg.h), which vmd implements in
 * usr.sbin/vmd/virtio.c.
 *
 * Two things differ beyond the offsets, and are why the seam is a set
 * of operations rather than a register map:
 *
 *   - the registers are not all 32 bits. Queue size and select and
 *     notify are 16, status and isr are 8, and an outl where an outw
 *     belongs writes the neighbouring register too.
 *   - there is no guest-page-size and no queue-align register. Both are
 *     4096 by definition here, which is what the mmio side writes
 *     anyway, so the ring layout comes out identical.
 *
 * Interrupts are the other half: a PCI device raises the line named in
 * its config space, which vmd routes through the 8259 (there is no
 * IOAPIC on that machine), and reading ISR_STATUS is what clears it --
 * no separate ack register.
 *
 * MSI-X is not used, so device config starts at 20
 * (DEVICE_CONFIG_NOMSI) and not 24.
 */

#include <string.h>

#include "microvm.h"
#include "virtio.h"

/* Virtio 0.9 config space, sys/dev/pci/virtio_pcireg.h */
#define VIO_DEVICE_FEATURES 0	/* 32 */
#define VIO_GUEST_FEATURES  4	/* 32 */
#define VIO_QUEUE_PFN       8	/* 32 */
#define VIO_QUEUE_SIZE     12	/* 16 */
#define VIO_QUEUE_SELECT   14	/* 16 */
#define VIO_QUEUE_NOTIFY   16	/* 16 */
#define VIO_DEVICE_STATUS  18	/* 8 */
#define VIO_ISR_STATUS     19	/* 8, clears on read */
#define VIO_CONFIG_NOMSI   20

#define PCI_VENDOR_VIRTIO 0x1af4

/* a virtio device's PCI id is 0x1040 + the virtio device type, which is
 * what vmd assigns (PCI_PRODUCT_QUMRANET_VIO1_NET is 0x1041 for type 1,
 * VIO1_RNG is 0x1044 for type 4). Transitional devices use 0x1000 + type
 * instead and are what qemu's PCI machines produce, so both are
 * accepted: the register layout this file drives is the same either way.
 */
#define VIRTIO_PCI_ID_MODERN 0x1040
#define VIRTIO_PCI_ID_LEGACY 0x1000

static inline void
outb(uint16_t port, uint8_t v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

static inline void
outw(uint16_t port, uint16_t v)
{
	__asm__ volatile ("outw %0, %1" : : "a" (v), "Nd" (port));
}

static inline void
outl(uint16_t port, uint32_t v)
{
	__asm__ volatile ("outl %0, %1" : : "a" (v), "Nd" (port));
}

static inline uint8_t
inb(uint16_t port)
{
	uint8_t v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static inline uint16_t
inw(uint16_t port)
{
	uint16_t v;

	__asm__ volatile ("inw %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static inline uint32_t
inl(uint16_t port)
{
	uint32_t v;

	__asm__ volatile ("inl %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static uint32_t
pci_get_features(struct virtio_dev *d)
{
	return inl(d->iobase + VIO_DEVICE_FEATURES);
}

static void
pci_set_features(struct virtio_dev *d, uint32_t v)
{
	outl(d->iobase + VIO_GUEST_FEATURES, v);
}

static void
pci_set_status(struct virtio_dev *d, uint8_t status)
{
	outb(d->iobase + VIO_DEVICE_STATUS, status);
}

static uint16_t
pci_queue_max(struct virtio_dev *d, unsigned qi)
{
	outw(d->iobase + VIO_QUEUE_SELECT, (uint16_t)qi);
	return inw(d->iobase + VIO_QUEUE_SIZE);
}

static void
pci_queue_setup(struct virtio_dev *d, unsigned qi, uint16_t qsize,
    uint32_t pfn)
{
	outw(d->iobase + VIO_QUEUE_SELECT, (uint16_t)qi);

	/* no queue-size write and no align: legacy PCI takes the size the
	 * device reported, and the alignment is 4096 by definition.
	 */
	(void)qsize;
	outl(d->iobase + VIO_QUEUE_PFN, pfn);
}

static void
pci_notify(struct virtio_dev *d, unsigned qi)
{
	outw(d->iobase + VIO_QUEUE_NOTIFY, (uint16_t)qi);
}

/* one register, and reading it is the acknowledgement -- vmd deasserts
 * the irq inside the read (usr.sbin/vmd/virtio.c). So this must be read
 * exactly once per interrupt, which is why the callers go through the
 * transport rather than peeking at status first.
 */
static uint32_t
pci_isr_ack(struct virtio_dev *d)
{
	return inb(d->iobase + VIO_ISR_STATUS);
}

static uint8_t
pci_config8(struct virtio_dev *d, unsigned off)
{
	return inb(d->iobase + VIO_CONFIG_NOMSI + off);
}

static const struct virtio_transport pci_transport = {
	.name = "pci",
	.get_features = pci_get_features,
	.set_features = pci_set_features,
	.set_status = pci_set_status,
	.queue_max = pci_queue_max,
	.queue_setup = pci_queue_setup,
	.notify = pci_notify,
	.isr_ack = pci_isr_ack,
	.config8 = pci_config8,
};

int
virtio_pci_find(uint32_t device_id, struct virtio_dev *out)
{
	struct pci_dev pd;
	uint16_t want_modern = (uint16_t)(VIRTIO_PCI_ID_MODERN + device_id);
	uint16_t want_legacy = (uint16_t)(VIRTIO_PCI_ID_LEGACY + device_id);

	if (pci_find(PCI_VENDOR_VIRTIO, want_modern, &pd) != 0 &&
	    pci_find(PCI_VENDOR_VIRTIO, want_legacy, &pd) != 0)
		return -1;

	if (pd.iobase == 0)
		return -1;	/* memory-mapped BAR only; not driven here */

	memset(out, 0, sizeof *out);
	out->t = &pci_transport;
	out->iobase = pd.iobase;
	out->slot = pd.dev;
	out->gsi = pd.irq;
	return 0;
}
