/* virtio over PCI, the modern (1.0) interface: the transport every
 * machine here has except qemu's microvm.
 *
 * Modern and not legacy, which was not a free choice. A device may be
 * called either of two things -- 0x1040 + type if it is
 * non-transitional, 0x1000 + type if it is transitional (4.1.2) -- and
 * only the first is guaranteed to have no legacy interface. Both are
 * accepted and both are driven the same way, through the modern
 * capability list, because that is the interface both have. Driving a
 * transitional device by its 0.9 layout instead reads a queue size of 0
 * from a register that means something else entirely.
 *
 * Nothing here is at a fixed offset. A modern device describes itself
 * through vendor-specific PCI capabilities (4.1.4), each naming a BAR
 * and an offset into it for one structure: common configuration,
 * notification, ISR status, device-specific configuration. So the
 * capability list is walked once at discovery and the four addresses
 * remembered, and every register access below is relative to one of
 * them.
 *
 * Which address space those live in is the device's choice, not the
 * machine's, and both occur: vmd asks for an IO BAR (pci_add_bar with
 * PCI_MAPREG_TYPE_IO in usr.sbin/vmd/virtio.c), while a q35 -- and
 * anything with a PCIe root port, which makes its devices
 * non-transitional -- gives memory BARs. vp_read/vp_write below is that
 * seam and the only place the difference appears.
 */

#include <string.h>

#include "microvm.h"
#include "virtio.h"

#define PCI_VENDOR_VIRTIO 0x1af4

/* a non-transitional device is 0x1040 + the virtio device type
 * (4.1.2), which is what vmd presents and what qemu gives behind a PCIe
 * root port.
 */
#define VIRTIO_PCI_ID_MODERN 0x1040

/* and the transitional spelling of the same device, which is what qemu
 * presents on a root bus. It is legacy-capable, which this makes no use
 * of: it carries the modern capability list too, and that is the only
 * interface driven here.
 *
 * The transitional ids are a table and not a formula (4.1.2): they were
 * assigned before the device types were, and the two numberings agree
 * only by accident -- entropy is type 4 but id 0x1005, ballooning is
 * type 5 but 0x1002. Deriving one from the other looks right for 9p
 * (type 9, id 0x1009) and is wrong for almost everything else.
 */
static uint16_t
transitional_id(uint32_t type)
{
	switch (type) {
	case 1: return 0x1000;		/* net */
	case 2: return 0x1001;		/* block */
	case 3: return 0x1003;		/* console */
	case 4: return 0x1005;		/* entropy */
	case 5: return 0x1002;		/* memory ballooning */
	case 8: return 0x1004;		/* scsi host */
	case 9: return 0x1009;		/* 9p */
	default: return 0xffff;		/* no transitional form */
	}
}

/* PCI capability list. Walking it is pci.c's, which knows nothing of
 * virtio beyond that a vendor-specific capability names its kind in the
 * byte at +3.
 */
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

/* register access in whichever space this device's BARs live in.
 *
 * Both spellings exist because both machines exist: vmd asks for an IO
 * BAR (pci_add_bar with PCI_MAPREG_TYPE_IO in usr.sbin/vmd/virtio.c)
 * and a q35 gives memory BARs, as does anything with a PCIe root port
 * -- a device behind one is non-transitional and has no IO BAR to
 * offer. The registers and their meanings are identical either way;
 * only the instruction that reaches them differs.
 *
 * No mapping step is needed for the memory side: boot.S identity-maps
 * the low 4GB, which is where firmware places these BARs, for the same
 * reason the LAPIC needs no mapping of its own.
 */
static inline uint8_t
vp_read8(struct virtio_dev *d, uint64_t at)
{
	if (d->pio)
		return inb((uint16_t)at);
	return *(volatile uint8_t *)(uintptr_t)at;
}

static inline uint16_t
vp_read16(struct virtio_dev *d, uint64_t at)
{
	if (d->pio)
		return inw((uint16_t)at);
	return *(volatile uint16_t *)(uintptr_t)at;
}

static inline uint32_t
vp_read32(struct virtio_dev *d, uint64_t at)
{
	if (d->pio)
		return inl((uint16_t)at);
	return *(volatile uint32_t *)(uintptr_t)at;
}

static inline void
vp_write8(struct virtio_dev *d, uint64_t at, uint8_t v)
{
	if (d->pio)
		outb((uint16_t)at, v);
	else
		*(volatile uint8_t *)(uintptr_t)at = v;
}

static inline void
vp_write16(struct virtio_dev *d, uint64_t at, uint16_t v)
{
	if (d->pio)
		outw((uint16_t)at, v);
	else
		*(volatile uint16_t *)(uintptr_t)at = v;
}

static inline void
vp_write32(struct virtio_dev *d, uint64_t at, uint32_t v)
{
	if (d->pio)
		outl((uint16_t)at, v);
	else
		*(volatile uint32_t *)(uintptr_t)at = v;
}

/* common-configuration accessors. The widths are the specification's
 * and are not interchangeable: a 32-bit write where a 16-bit one
 * belongs lands on the neighbouring field as well, and the fields are
 * packed tightly enough that there is always a neighbour.
 */
static inline uint64_t
cc(struct virtio_dev *d, unsigned off)
{
	return d->cfg_common + off;
}

/* a 64-bit field, low half first. The specification allows a device to
 * act on the write of either half, so the order is the one every driver
 * uses and the one devices are tested against.
 */
static void
cc_write64(struct virtio_dev *d, unsigned off, uint64_t v)
{
	vp_write32(d, cc(d, off), (uint32_t)v);
	vp_write32(d, cc(d, off + 4), (uint32_t)(v >> 32));
}

static uint64_t
pci_get_features(struct virtio_dev *d)
{
	uint64_t lo, hi;

	vp_write32(d, cc(d, COMMON_DEVICE_FEATURE_SELECT), 0);
	lo = vp_read32(d, cc(d, COMMON_DEVICE_FEATURE));
	vp_write32(d, cc(d, COMMON_DEVICE_FEATURE_SELECT), 1);
	hi = vp_read32(d, cc(d, COMMON_DEVICE_FEATURE));
	return lo | (hi << 32);
}

static void
pci_set_features(struct virtio_dev *d, uint64_t v)
{
	vp_write32(d, cc(d, COMMON_DRIVER_FEATURE_SELECT), 0);
	vp_write32(d, cc(d, COMMON_DRIVER_FEATURE), (uint32_t)v);
	vp_write32(d, cc(d, COMMON_DRIVER_FEATURE_SELECT), 1);
	vp_write32(d, cc(d, COMMON_DRIVER_FEATURE), (uint32_t)(v >> 32));
}

static void
pci_set_status(struct virtio_dev *d, uint8_t status)
{
	vp_write8(d, cc(d, COMMON_DEVICE_STATUS), status);
}

static uint8_t
pci_get_status(struct virtio_dev *d)
{
	return vp_read8(d, cc(d, COMMON_DEVICE_STATUS));
}

static uint16_t
pci_queue_max(struct virtio_dev *d, unsigned qi)
{
	vp_write16(d, cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);
	return vp_read16(d, cc(d, COMMON_QUEUE_SIZE));
}

static void
pci_queue_setup(struct virtio_dev *d, unsigned qi, uint16_t qsize,
    uint64_t desc, uint64_t avail, uint64_t used)
{
	vp_write16(d, cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);
	vp_write16(d, cc(d, COMMON_QUEUE_SIZE), qsize);

	/* the three rings, named separately -- the whole reason the seam
	 * takes addresses and not a page number.
	 */
	cc_write64(d, COMMON_QUEUE_DESC, desc);
	cc_write64(d, COMMON_QUEUE_DRIVER, avail);
	cc_write64(d, COMMON_QUEUE_DEVICE, used);

	/* and a step legacy has no equivalent of: a modern queue is
	 * configured and then separately switched on.
	 */
	vp_write16(d, cc(d, COMMON_QUEUE_ENABLE), 1);
}

/* the notify address is per queue and is derived, not fixed: the
 * capability gives a base and a multiplier, the common configuration
 * gives this queue's offset (4.1.4.4).
 */
static void
pci_notify(struct virtio_dev *d, unsigned qi)
{
	vp_write16(d, cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);

	uint16_t off = vp_read16(d, cc(d, COMMON_QUEUE_NOTIFY_OFF));

	vp_write16(d, d->cfg_notify + (uint64_t)off * d->notify_mul,
	    (uint16_t)qi);
}

/* one byte, and reading it is the acknowledgement -- vmd deasserts the
 * irq inside the read (usr.sbin/vmd/virtio.c). So it must be read
 * exactly once per interrupt, which is why callers go through this
 * rather than peeking at a status first.
 */
static uint32_t
pci_isr_ack(struct virtio_dev *d)
{
	return vp_read8(d, d->cfg_isr);
}

static uint8_t
pci_config8(struct virtio_dev *d, unsigned off)
{
	return vp_read8(d, d->cfg_device + off);
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
 *
 * Each capability names a BAR by register index and an offset into it,
 * and all four may be in different BARs -- qemu puts the virtio
 * structures in one and the MSI-X table in another. So the BAR is
 * resolved per capability rather than once for the device, and a
 * capability naming a BAR that firmware left unassigned is one this
 * cannot reach.
 */
static int
read_caps(const struct pci_dev *pd, struct virtio_dev *out)
{
	int have_common = 0, have_notify = 0;
	unsigned off = (unsigned)pci_cap_find(pd, CAP_ID_VENDOR, -1);

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

		if (bar >= PCI_NUM_BARS || pd->bar[bar].base == 0)
			goto next;

		/* one device cannot be half in each space: the first
		 * capability decides, and the rest must agree.
		 */
		uint64_t at = pd->bar[bar].base + cap_off;

		switch (cfgtype) {
		case VIRTIO_PCI_CAP_COMMON_CFG:
			out->pio = pd->bar[bar].is_io;
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

/* MSI-X, when the device offers it.
 *
 * Not a preference but a requirement on the machines that have it: a
 * device behind a PCIe root port has no usable INTx line to fall back
 * on -- the pin is routed through the port to a PIRQ, and working out
 * which GSI that became needs the ACPI _PRT this platform does not
 * parse. MSI-X sidesteps the question entirely, since the message names
 * the vector: the device writes the address the LAPIC decodes and the
 * interrupt arrives on the vector we chose, with no controller in
 * between to interrogate.
 *
 * One vector for the whole device, in table entry 0, which every queue
 * and the configuration change are pointed at. The handler already asks
 * every device what happened rather than trusting the vector to say
 * (see virtio_isr), so per-queue vectors would buy nothing here.
 */
#define CAP_ID_MSIX      0x11
#define MSIX_TABLE       0x04	/* le32: BAR index in bits 2:0, offset above */
#define MSIX_CTL_ENABLE  0x8000
#define MSIX_CTL_MASKALL 0x4000

/* struct msix_entry, 16 bytes */
#define MSIX_ENT_ADDR_LO 0x0
#define MSIX_ENT_ADDR_HI 0x4
#define MSIX_ENT_DATA    0x8
#define MSIX_ENT_VECTCTL 0xc
#define MSIX_VECTCTL_MASK 0x1

/* the LAPIC's message address (SDM 10.11.1): a fixed prefix, the
 * destination apic id, and physical delivery mode. Where the low 32
 * bits of that window sit is not a coincidence -- it is the same
 * 0xFEE00000 the LAPIC registers are at, decoded by the CPU rather than
 * by any device on the bus.
 */
#define MSI_ADDR_BASE 0xfee00000UL

#define VIRTIO_MSIX_NO_VECTOR 0xffff

static int
msix_enable(const struct pci_dev *pd, struct virtio_dev *out, int vector)
{
	int cap = pci_cap_find(pd, CAP_ID_MSIX, -1);

	if (cap == 0)
		return -1;

	uint32_t ctl_word = pci_config_read(pd->bus, pd->dev, pd->fn, cap);
	uint16_t ctl = (uint16_t)(ctl_word >> 16);
	uint32_t tbl = pci_config_read(pd->bus, pd->dev, pd->fn,
	    cap + MSIX_TABLE);
	unsigned bar = tbl & 0x7;

	if (bar >= PCI_NUM_BARS || pd->bar[bar].base == 0 ||
	    pd->bar[bar].is_io)
		return -1;	/* the table is always in a memory BAR */

	uint64_t ent = pd->bar[bar].base + (tbl & ~0x7UL);

	/* mask the entry while it is being written, since the device may
	 * raise the moment the address is plausible.
	 */
	*(volatile uint32_t *)(uintptr_t)(ent + MSIX_ENT_VECTCTL) =
	    MSIX_VECTCTL_MASK;
	*(volatile uint32_t *)(uintptr_t)(ent + MSIX_ENT_ADDR_LO) =
	    (uint32_t)(MSI_ADDR_BASE | ((uint32_t)lapic_id() << 12));
	*(volatile uint32_t *)(uintptr_t)(ent + MSIX_ENT_ADDR_HI) = 0;
	*(volatile uint32_t *)(uintptr_t)(ent + MSIX_ENT_DATA) =
	    (uint32_t)vector;
	*(volatile uint32_t *)(uintptr_t)(ent + MSIX_ENT_VECTCTL) = 0;

	/* enable the capability, and clear the function mask that would
	 * otherwise hold every entry down regardless.
	 */
	ctl |= MSIX_CTL_ENABLE;
	ctl &= (uint16_t)~MSIX_CTL_MASKALL;
	pci_config_write(pd->bus, pd->dev, pd->fn, cap,
	    (ctl_word & 0xffff) | ((uint32_t)ctl << 16));

	out->msix_table = ent;
	out->msix_vector = vector;
	return 0;
}

/* point the device at its one vector: every queue and the configuration
 * change. Must follow feature negotiation and precede DRIVER_OK, which
 * is what makes it a step of its own rather than part of discovery --
 * the common configuration is not writable before the device has been
 * acknowledged.
 */
void
virtio_pci_msix_arm(struct virtio_dev *d, unsigned nqueues)
{
	if (d->t != &pci_transport || d->msix_table == 0)
		return;

	vp_write16(d, cc(d, COMMON_CONFIG_MSIX_VECTOR), 0);

	for (unsigned qi = 0; qi < nqueues; qi++) {
		vp_write16(d, cc(d, COMMON_QUEUE_SELECT), (uint16_t)qi);
		vp_write16(d, cc(d, COMMON_QUEUE_MSIX_VECTOR), 0);

		/* a device that could not take the vector says so by
		 * reading back NO_VECTOR (4.1.4.3.1), and an unnoticed
		 * refusal is a queue whose completions never arrive.
		 */
		if (vp_read16(d, cc(d, COMMON_QUEUE_MSIX_VECTOR)) ==
		    VIRTIO_MSIX_NO_VECTOR) {
			d->msix_table = 0;
			return;
		}
	}
}

int
virtio_pci_find(uint32_t device_id, struct virtio_dev *out)
{
	struct pci_dev pd;

	/* both spellings of the same device. Which one a machine presents
	 * is not a choice it makes about the device but a consequence of
	 * where the device sits: behind a PCIe root port qemu makes it
	 * non-transitional, on a root bus it makes it transitional. Either
	 * is driven identically, because what decides that is the
	 * capability list below and not the name.
	 */
	if (pci_find2(PCI_VENDOR_VIRTIO,
	    (uint16_t)(VIRTIO_PCI_ID_MODERN + device_id),
	    transitional_id(device_id), &pd) != 0)
		return -1;

	memset(out, 0, sizeof *out);
	out->t = &pci_transport;
	out->slot = pd.dev;
	out->gsi = pd.irq;

	if (read_caps(&pd, out) != 0)
		return -1;

	/* MSI-X if the device has it, INTx if it does not. Discovery is
	 * where this belongs even though arming the queues cannot happen
	 * until later: whether the device has a table at all decides which
	 * of the two virtio_irq_enable installs, and that has to be known
	 * before anything is routed.
	 *
	 * A device with no MSI-X keeps the line config space named. That
	 * is vmd, where INTLINE is the answer; on a machine where it is
	 * not, this device has a table.
	 */
	int vector = intr_alloc_vector();

	if (vector >= 0 && msix_enable(&pd, out, vector) == 0)
		virtio_msi_route(vector);

	return 0;
}
