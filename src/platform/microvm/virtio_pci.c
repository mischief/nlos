/* virtio over PCI, the modern (1.0) interface: the transport OpenBSD
 * vmd has.
 *
 * Modern and not legacy, which was not a free choice. vmd's devices
 * carry PCI ids 0x1040 + type -- 0x1044 for the rng this was brought up
 * against -- and the specification is explicit that a non-transitional
 * device (4.1.2) has no legacy interface at all; only transitional
 * devices, at 0x1000 + type, answer the 0.9 register layout. Driving it
 * as legacy read a queue size of 0 from a register that means something
 * else entirely, which is what that mistake looks like from the guest.
 *
 * Nothing here is at a fixed offset. A modern device describes itself
 * through vendor-specific PCI capabilities (4.1.4), each naming a BAR
 * and an offset into it for one structure: common configuration,
 * notification, ISR status, device-specific configuration. So the
 * capability list is walked once at discovery and the four offsets
 * remembered, and every register access below is relative to one of
 * them.
 *
 * The BAR is an IO BAR here, because that is what vmd asks for
 * (pci_add_bar with PCI_MAPREG_TYPE_IO in usr.sbin/vmd/virtio.c). A
 * device whose capabilities point at a memory BAR would need mapped
 * accessors instead; there is none on this machine, and discovery
 * declines rather than guessing.
 */

#include <string.h>

#include "microvm.h"
#include "virtio.h"

#define PCI_VENDOR_VIRTIO 0x1af4

/* a modern device is 0x1040 + the virtio device type (4.1.2). The
 * transitional 0x1000 + type spelling is deliberately not accepted: a
 * transitional device is legacy-capable and would need the 0.9 layout,
 * which is a different file that does not exist -- and no machine here
 * presents one.
 */
#define VIRTIO_PCI_ID_MODERN 0x1040

/* PCI capability list */
#define CFG_STATUS       0x04	/* capability-list bit lives in the high half */
#define CFG_CAP_PTR      0x34
#define STATUS_CAP_LIST  (1u << 20)	/* bit 4 of the status half of 0x04 */
#define CAP_ID_VENDOR    0x09

/* struct virtio_pci_cap (4.1.4), as byte offsets from the capability */
#define CAP_VNDR    0
#define CAP_NEXT    1
#define CAP_LEN     2
#define CAP_CFGTYPE 3
#define CAP_BAR     4
#define CAP_OFFSET  8
#define CAP_LENGTH  12
#define CAP_NOTIFY_MULTIPLIER 16	/* struct virtio_pci_notify_cap */

#define VIRTIO_PCI_CAP_COMMON_CFG 1
#define VIRTIO_PCI_CAP_NOTIFY_CFG 2
#define VIRTIO_PCI_CAP_ISR_CFG    3
#define VIRTIO_PCI_CAP_DEVICE_CFG 4

/* struct virtio_pci_common_cfg (4.1.4.3), byte offsets from its start */
#define COMMON_DEVICE_FEATURE_SELECT 0x00	/* le32 */
#define COMMON_DEVICE_FEATURE        0x04	/* le32 */
#define COMMON_DRIVER_FEATURE_SELECT 0x08	/* le32 */
#define COMMON_DRIVER_FEATURE        0x0c	/* le32 */
#define COMMON_CONFIG_MSIX_VECTOR    0x10	/* le16 */
#define COMMON_NUM_QUEUES            0x12	/* le16 */
#define COMMON_DEVICE_STATUS         0x14	/* u8 */
#define COMMON_CONFIG_GENERATION     0x15	/* u8 */
#define COMMON_QUEUE_SELECT          0x16	/* le16 */
#define COMMON_QUEUE_SIZE            0x18	/* le16 */
#define COMMON_QUEUE_MSIX_VECTOR     0x1a	/* le16 */
#define COMMON_QUEUE_ENABLE          0x1c	/* le16 */
#define COMMON_QUEUE_NOTIFY_OFF      0x1e	/* le16 */
#define COMMON_QUEUE_DESC            0x20	/* le64 */
#define COMMON_QUEUE_DRIVER          0x28	/* le64 */
#define COMMON_QUEUE_DEVICE          0x30	/* le64 */

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

/* common-configuration accessors. The widths are the specification's
 * and are not interchangeable: an outl where an outw belongs writes the
 * neighbouring field as well, and the fields are packed tightly enough
 * that there is always a neighbour.
 */
static inline uint16_t
cc(struct virtio_dev *d, unsigned off)
{
	return (uint16_t)(d->cfg_common + off);
}

/* a 64-bit field, low half first. The specification allows a device to
 * act on the write of either half, so the order is the one every driver
 * uses and the one devices are tested against.
 */
static void
cc_write64(struct virtio_dev *d, unsigned off, uint64_t v)
{
	outl(cc(d, off), (uint32_t)v);
	outl(cc(d, off + 4), (uint32_t)(v >> 32));
}

static uint64_t
pci_get_features(struct virtio_dev *d)
{
	uint64_t lo, hi;

	outl(cc(d, COMMON_DEVICE_FEATURE_SELECT), 0);
	lo = inl(cc(d, COMMON_DEVICE_FEATURE));
	outl(cc(d, COMMON_DEVICE_FEATURE_SELECT), 1);
	hi = inl(cc(d, COMMON_DEVICE_FEATURE));
	return lo | (hi << 32);
}

static void
pci_set_features(struct virtio_dev *d, uint64_t v)
{
	outl(cc(d, COMMON_DRIVER_FEATURE_SELECT), 0);
	outl(cc(d, COMMON_DRIVER_FEATURE), (uint32_t)v);
	outl(cc(d, COMMON_DRIVER_FEATURE_SELECT), 1);
	outl(cc(d, COMMON_DRIVER_FEATURE), (uint32_t)(v >> 32));
}

static void
pci_set_status(struct virtio_dev *d, uint8_t status)
{
	outb(cc(d, COMMON_DEVICE_STATUS), status);
}

static uint8_t
pci_get_status(struct virtio_dev *d)
{
	return inb(cc(d, COMMON_DEVICE_STATUS));
}

static uint16_t
pci_queue_max(struct virtio_dev *d, unsigned qi)
{
	outw(cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);
	return inw(cc(d, COMMON_QUEUE_SIZE));
}

static void
pci_queue_setup(struct virtio_dev *d, unsigned qi, uint16_t qsize,
    uint64_t desc, uint64_t avail, uint64_t used)
{
	outw(cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);
	outw(cc(d, COMMON_QUEUE_SIZE), qsize);

	/* the three rings, named separately -- the whole reason the seam
	 * takes addresses and not a page number.
	 */
	cc_write64(d, COMMON_QUEUE_DESC, desc);
	cc_write64(d, COMMON_QUEUE_DRIVER, avail);
	cc_write64(d, COMMON_QUEUE_DEVICE, used);

	/* and a step legacy has no equivalent of: a modern queue is
	 * configured and then separately switched on.
	 */
	outw(cc(d, COMMON_QUEUE_ENABLE), 1);
}

/* the notify address is per queue and is derived, not fixed: the
 * capability gives a base and a multiplier, the common configuration
 * gives this queue's offset (4.1.4.4).
 */
static void
pci_notify(struct virtio_dev *d, unsigned qi)
{
	outw(cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);

	uint16_t off = inw(cc(d, COMMON_QUEUE_NOTIFY_OFF));

	outw((uint16_t)(d->cfg_notify + off * d->notify_mul), (uint16_t)qi);
}

/* one byte, and reading it is the acknowledgement -- vmd deasserts the
 * irq inside the read (usr.sbin/vmd/virtio.c). So it must be read
 * exactly once per interrupt, which is why callers go through this
 * rather than peeking at a status first.
 */
static uint32_t
pci_isr_ack(struct virtio_dev *d)
{
	return inb(d->cfg_isr);
}

static uint8_t
pci_config8(struct virtio_dev *d, unsigned off)
{
	return inb((uint16_t)(d->cfg_device + off));
}

static const struct virtio_transport pci_transport = {
	.name = "pci",
	.required_features = VIRTIO_F_VERSION_1,
	.get_features = pci_get_features,
	.set_features = pci_set_features,
	.set_status = pci_set_status,
	.get_status = pci_get_status,
	.queue_max = pci_queue_max,
	.queue_setup = pci_queue_setup,
	.notify = pci_notify,
	.isr_ack = pci_isr_ack,
	.config8 = pci_config8,
};

/* walk the capability list, remembering where each virtio structure
 * lives. Returns 0 if at least the common configuration and the
 * notification structure were found, which are the two without which
 * nothing can be driven.
 */
static int
read_caps(struct pci_dev *pd, struct virtio_dev *out)
{
	uint32_t status = pci_config_read(pd->bus, pd->dev, pd->fn, CFG_STATUS);

	if (!(status & STATUS_CAP_LIST))
		return -1;

	unsigned off = pci_config_read(pd->bus, pd->dev, pd->fn,
	    CFG_CAP_PTR) & 0xfc;
	int have_common = 0, have_notify = 0;

	/* a malformed list could loop; the space it walks is 256 bytes and
	 * a capability is at least 4, so this many steps is beyond generous.
	 */
	for (int guard = 0; off >= 0x40 && off < 0x100 && guard < 64; guard++) {
		uint32_t w0 = pci_config_read(pd->bus, pd->dev, pd->fn, off);
		uint8_t id = (uint8_t)(w0 & 0xff);
		uint8_t next = (uint8_t)((w0 >> 8) & 0xff);

		if (id != CAP_ID_VENDOR)
			goto next;

		uint8_t cfgtype = (uint8_t)((w0 >> 24) & 0xff);
		uint32_t bar = pci_config_read(pd->bus, pd->dev, pd->fn,
		    off + CAP_BAR) & 0xff;
		uint32_t cap_off = pci_config_read(pd->bus, pd->dev, pd->fn,
		    off + CAP_OFFSET);

		/* every structure this drives has to be in the IO BAR that
		 * discovery already resolved. A capability naming another
		 * BAR is one this cannot reach.
		 */
		if (bar != 0)
			goto next;

		uint16_t at = (uint16_t)(out->iobase + cap_off);

		switch (cfgtype) {
		case VIRTIO_PCI_CAP_COMMON_CFG:
			out->cfg_common = at;
			have_common = 1;
			break;
		case VIRTIO_PCI_CAP_NOTIFY_CFG:
			out->cfg_notify = at;
			out->notify_mul = pci_config_read(pd->bus, pd->dev,
			    pd->fn, off + CAP_NOTIFY_MULTIPLIER);
			have_notify = 1;
			break;
		case VIRTIO_PCI_CAP_ISR_CFG:
			out->cfg_isr = at;
			break;
		case VIRTIO_PCI_CAP_DEVICE_CFG:
			out->cfg_device = at;
			break;
		default:
			break;
		}
next:
		if (next == 0)
			break;
		off = next & 0xfc;
	}

	return (have_common && have_notify) ? 0 : -1;
}

int
virtio_pci_find(uint32_t device_id, struct virtio_dev *out)
{
	struct pci_dev pd;

	if (pci_find(PCI_VENDOR_VIRTIO,
	    (uint16_t)(VIRTIO_PCI_ID_MODERN + device_id), &pd) != 0)
		return -1;

	if (pd.iobase == 0)
		return -1;	/* memory BAR only; not driven here */

	memset(out, 0, sizeof *out);
	out->t = &pci_transport;
	out->iobase = pd.iobase;
	out->slot = pd.dev;
	out->gsi = pd.irq;

	if (read_caps(&pd, out) != 0)
		return -1;
	return 0;
}
