/* virtio-mmio: the transport qemu's microvm machine has.
 *
 * Discovery is a fixed scan, not a bus walk: microvm has exactly 8
 * virtio-mmio slots at a fixed base and stride (see qemu's
 * include/hw/i386/microvm.h), already covered by the flat identity map
 * (src/platform/microvm/boot.S), so there is no MMIO window to set up
 * beyond reading the registers.
 *
 * Legacy (version 1) mode throughout: qemu's virtio-mmio defaults to
 * force-legacy=true and microvm never overrides it (hw/i386/virtio-mmio.c,
 * hw/i386/microvm.c), so this is the only mode a microvm guest sees.
 * The ring layout that implies is virtio.c's business; this file is
 * only how the registers are reached.
 */

#include <string.h>

#include "microvm.h"
#include "virtio.h"

#define VIRTIO_MMIO_BASE   0xfeb00000UL
#define VIRTIO_MMIO_STRIDE 0x200UL	/* 512 */
#define VIRTIO_NUM_SLOTS   8

#define MAGIC_VALUE 0x74726976UL	/* "virt" */

#define REG_MAGIC             0x000
#define REG_VERSION           0x004
#define REG_DEVICE_ID         0x008
#define REG_DEV_FEATURES      0x010
#define REG_DEV_FEATURES_SEL  0x014
#define REG_DRV_FEATURES      0x020
#define REG_DRV_FEATURES_SEL  0x024
#define REG_GUEST_PAGE_SIZE   0x028
#define REG_QUEUE_SEL         0x030
#define REG_QUEUE_NUM_MAX     0x034
#define REG_QUEUE_NUM         0x038
#define REG_QUEUE_ALIGN       0x03c
#define REG_QUEUE_PFN         0x040
#define REG_QUEUE_NOTIFY      0x050
#define REG_INT_STATUS        0x060
#define REG_INT_ACK           0x064
#define REG_STATUS            0x070
#define REG_CONFIG            0x100

#define PAGE_SIZE 4096

static inline uint32_t
rd(struct virtio_dev *d, unsigned off)
{
	return d->regs[off / 4];
}

static inline void
wr(struct virtio_dev *d, unsigned off, uint32_t v)
{
	d->regs[off / 4] = v;
}

/* word 0 only.
 *
 * A legacy device has no feature bits above 31 -- VERSION_1 is bit 32,
 * and its absence is precisely what makes this the legacy interface --
 * so reading the high word would be reading a register the device does
 * not implement. The seam is 64 bits wide because the other transport
 * needs it to be; here the top half is always zero.
 */
static uint64_t
mmio_get_features(struct virtio_dev *d)
{
	wr(d, REG_DEV_FEATURES_SEL, 0);
	return rd(d, REG_DEV_FEATURES);
}

static void
mmio_set_features(struct virtio_dev *d, uint64_t v)
{
	wr(d, REG_DRV_FEATURES_SEL, 0);
	wr(d, REG_DRV_FEATURES, (uint32_t)v);

	/* the page size every ring address is expressed in. PCI has no
	 * such register: there it is 4096 by definition, which is what
	 * this writes, so both transports end up saying the same thing.
	 */
	wr(d, REG_GUEST_PAGE_SIZE, PAGE_SIZE);
}

static void
mmio_set_status(struct virtio_dev *d, uint8_t status)
{
	wr(d, REG_STATUS, status);
}

static uint8_t
mmio_get_status(struct virtio_dev *d)
{
	return (uint8_t)rd(d, REG_STATUS);
}

static uint16_t
mmio_queue_max(struct virtio_dev *d, unsigned qi)
{
	wr(d, REG_QUEUE_SEL, qi);
	return (uint16_t)rd(d, REG_QUEUE_NUM_MAX);
}

/* the legacy transport addresses all three rings with the one page
 * number they start at, so avail and used are implied by desc and the
 * layout virtio.c built. Taking them and dropping them keeps the caller
 * from having to know which transport it is talking to.
 */
static void
mmio_queue_setup(struct virtio_dev *d, unsigned qi, uint16_t qsize,
    uint64_t desc, uint64_t avail, uint64_t used)
{
	(void)avail;
	(void)used;

	wr(d, REG_QUEUE_SEL, qi);
	wr(d, REG_QUEUE_NUM, qsize);
	wr(d, REG_QUEUE_ALIGN, PAGE_SIZE);
	wr(d, REG_QUEUE_PFN, (uint32_t)(desc / PAGE_SIZE));
}

static void
mmio_notify(struct virtio_dev *d, unsigned qi)
{
	wr(d, REG_QUEUE_NOTIFY, qi);
}

/* two registers here, unlike PCI's clear-on-read: the status says what
 * happened and the ack is what lowers the level at the source.
 */
static uint32_t
mmio_isr_ack(struct virtio_dev *d)
{
	uint32_t is = rd(d, REG_INT_STATUS);

	if (is)
		wr(d, REG_INT_ACK, is);
	return is;
}

static uint8_t
mmio_config8(struct virtio_dev *d, unsigned off)
{
	volatile uint8_t *cfg = (volatile uint8_t *)d->regs + REG_CONFIG;

	return cfg[off];
}

static uint32_t
mmio_config32(struct virtio_dev *d, unsigned off)
{
	volatile uint32_t *cfg = (volatile uint32_t *)
	    ((volatile uint8_t *)d->regs + REG_CONFIG);

	return cfg[off / 4];
}

static const struct virtio_transport mmio_transport = {
	.name = "mmio",
	.required_features = 0,		/* legacy by construction */
	.get_features = mmio_get_features,
	.set_features = mmio_set_features,
	.set_status = mmio_set_status,
	.get_status = mmio_get_status,
	.queue_max = mmio_queue_max,
	.queue_setup = mmio_queue_setup,
	.notify = mmio_notify,
	.isr_ack = mmio_isr_ack,
	.config8 = mmio_config8,
	.config32 = mmio_config32,
};

int
virtio_mmio_find(uint32_t device_id, struct virtio_dev *out)
{
	for (int i = 0; i < VIRTIO_NUM_SLOTS; i++) {
		volatile uint32_t *regs = (volatile uint32_t *)
		    (VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE);

		if (regs[REG_MAGIC / 4] != MAGIC_VALUE)
			continue;
		if (regs[REG_DEVICE_ID / 4] != device_id)
			continue;

		memset(out, 0, sizeof *out);
		out->t = &mmio_transport;
		out->regs = regs;
		out->slot = i;

		/* qemu wires the eight slots to consecutive GSIs from
		 * VIRTIO_MMIO_IRQ_BASE (hw/i386/microvm.c), so the slot a
		 * device answers in is also its line.
		 */
		out->gsi = VIRTIO_MMIO_GSI_BASE + i;
		return 0;
	}
	return -1;
}
