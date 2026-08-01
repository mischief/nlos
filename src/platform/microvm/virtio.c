/* virtio-mmio core: register access, legacy queue setup, one
 * synchronous single-descriptor submit/poll path. see virtio.h.
 *
 * device discovery is a fixed scan, not a bus walk: microvm has
 * exactly 8 virtio-mmio slots at a fixed base and stride (see
 * qemu's include/hw/i386/microvm.h), already covered by the flat
 * identity map (src/platform/microvm/boot.S), so there is no MMIO
 * window to set up beyond reading the registers.
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
#define REG_STATUS            0x070

#define STATUS_ACK        0x01
#define STATUS_DRIVER     0x02
#define STATUS_DRIVER_OK  0x04

#define DESC_F_NEXT  1
#define DESC_F_WRITE 2

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

static size_t
align_up(size_t n, size_t a)
{
	return (n + (a - 1)) & ~(a - 1);
}

int
virtio_find(uint32_t device_id, struct virtio_dev *out)
{
	for (int i = 0; i < VIRTIO_NUM_SLOTS; i++) {
		volatile uint32_t *regs =
		    (volatile uint32_t *)(VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE);

		if (regs[REG_MAGIC / 4] != MAGIC_VALUE)
			continue;
		if (regs[REG_DEVICE_ID / 4] != device_id)
			continue;
		memset(out, 0, sizeof *out);
		out->regs = regs;
		return 0;
	}
	return -1;
}

int
virtio_dev_init(struct virtio_dev *d, uint16_t qsize)
{
	wr(d, REG_STATUS, 0);				/* reset */
	wr(d, REG_STATUS, STATUS_ACK);
	wr(d, REG_STATUS, STATUS_ACK | STATUS_DRIVER);

	/* accept no optional features -- rng needs none */
	wr(d, REG_DEV_FEATURES_SEL, 0);
	(void)rd(d, REG_DEV_FEATURES);
	wr(d, REG_DRV_FEATURES_SEL, 0);
	wr(d, REG_DRV_FEATURES, 0);

	wr(d, REG_GUEST_PAGE_SIZE, PAGE_SIZE);

	wr(d, REG_QUEUE_SEL, 0);
	uint32_t max = rd(d, REG_QUEUE_NUM_MAX);

	if (max == 0)
		return -1;
	if (qsize > max)
		qsize = (uint16_t)max;
	wr(d, REG_QUEUE_NUM, qsize);
	wr(d, REG_QUEUE_ALIGN, PAGE_SIZE);

	/* legacy layout: desc[qsize], avail hdr+ring+used_event, padding
	 * to QUEUE_ALIGN, then used hdr+ring+avail_event.
	 */
	size_t desc_sz = (size_t)qsize * sizeof(struct virtq_desc);
	size_t avail_sz = 4 + 2 * (size_t)qsize + 2;
	size_t used_off = align_up(desc_sz + avail_sz, PAGE_SIZE);
	size_t used_sz = 4 + 8 * (size_t)qsize + 2;
	size_t total = align_up(used_off + used_sz, PAGE_SIZE);

	/* pmm_alloc gives no alignment guarantee, so over-allocate and
	 * align the returned pointer ourselves -- QUEUE_PFN is a page
	 * number, the device will not accept anything less.
	 */
	void *raw = pmm_alloc(total + PAGE_SIZE - 1);

	if (!raw)
		return -1;
	uintptr_t mem = align_up((uintptr_t)raw, PAGE_SIZE);

	memset((void *)mem, 0, total);

	d->desc = (struct virtq_desc *)mem;
	d->avail = (volatile struct virtq_avail *)(mem + desc_sz);
	d->avail_ring = (uint16_t *)((char *)d->avail + sizeof(struct virtq_avail));
	d->used = (volatile struct virtq_used *)(mem + used_off);
	d->used_ring = (struct virtq_used_elem *)((char *)d->used + sizeof(struct virtq_used));
	d->qsize = qsize;
	d->last_used_idx = 0;

	wr(d, REG_QUEUE_PFN, (uint32_t)(mem / PAGE_SIZE));

	wr(d, REG_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);
	return 0;
}

/* submits the descriptor chain starting at head (already filled in),
 * kicks the device, and busy-waits for the used ring. returns the
 * byte count the device reports writing, or -1.
 */
static int
kick_and_wait(struct virtio_dev *d, uint16_t head)
{
	__asm__ volatile ("" ::: "memory");	/* desc(s) visible before avail */

	uint16_t idx = d->avail->idx;

	d->avail_ring[idx % d->qsize] = head;
	__asm__ volatile ("" ::: "memory");	/* ring entry before idx bump */
	d->avail->idx = idx + 1;
	__asm__ volatile ("" ::: "memory");	/* idx visible before notify */

	wr(d, REG_QUEUE_NOTIFY, 0);

	while (d->used->idx == d->last_used_idx)
		__asm__ volatile ("pause" ::: "memory");

	struct virtq_used_elem *e = &d->used_ring[d->last_used_idx % d->qsize];
	uint32_t got = e->len;

	d->last_used_idx++;
	return (int)got;
}

int
virtio_submit_write_poll(struct virtio_dev *d, void *buf, uint32_t n)
{
	/* descriptor 0, reused every call: one request in flight at a
	 * time, matching this function's synchronous contract.
	 */
	d->desc[0].addr = (uint64_t)(uintptr_t)buf;
	d->desc[0].len = n;
	d->desc[0].flags = DESC_F_WRITE;
	d->desc[0].next = 0;

	return kick_and_wait(d, 0);
}

int
virtio_submit_rpc_poll(struct virtio_dev *d, const void *req, uint32_t reqlen,
    void *rep, uint32_t repcap)
{
	/* descriptors 0 (readable, the request) -> 1 (writable, the
	 * reply), reused every call -- same single-outstanding-request
	 * contract as virtio_submit_write_poll.
	 */
	d->desc[0].addr = (uint64_t)(uintptr_t)req;
	d->desc[0].len = reqlen;
	d->desc[0].flags = DESC_F_NEXT;
	d->desc[0].next = 1;

	d->desc[1].addr = (uint64_t)(uintptr_t)rep;
	d->desc[1].len = repcap;
	d->desc[1].flags = DESC_F_WRITE;
	d->desc[1].next = 0;

	return kick_and_wait(d, 0);
}
