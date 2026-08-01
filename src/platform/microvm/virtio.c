/* virtio-mmio core: register access, legacy queue setup, descriptor
 * allocation, and both a synchronous and an asynchronous submit path.
 * See virtio.h.
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
#define REG_INT_STATUS        0x060
#define REG_INT_ACK           0x064
#define REG_STATUS            0x070

#define STATUS_ACK        0x01
#define STATUS_DRIVER     0x02
#define STATUS_DRIVER_OK  0x04

#define DESC_F_NEXT  1
#define DESC_F_WRITE 2

#define PAGE_SIZE 4096

/* the compiler must not move descriptor or ring writes across these:
 * the device reads the same memory concurrently. On x86 the hardware
 * ordering is already strong enough, so a compiler barrier is the whole
 * requirement here.
 */
#define barrier() __asm__ volatile ("" ::: "memory")

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
		out->slot = i;		/* fixes its gsi; see virtio_irq_enable */
		return 0;
	}
	return -1;
}

int
virtio_dev_begin(struct virtio_dev *d, uint32_t want, uint32_t *got)
{
	wr(d, REG_STATUS, 0);				/* reset */
	wr(d, REG_STATUS, STATUS_ACK);
	wr(d, REG_STATUS, STATUS_ACK | STATUS_DRIVER);

	wr(d, REG_DEV_FEATURES_SEL, 0);

	uint32_t offered = rd(d, REG_DEV_FEATURES);
	uint32_t accept = offered & want;

	wr(d, REG_DRV_FEATURES_SEL, 0);
	wr(d, REG_DRV_FEATURES, accept);

	if (got)
		*got = accept;

	wr(d, REG_GUEST_PAGE_SIZE, PAGE_SIZE);
	return 0;
}

int
virtio_queue_init(struct virtio_dev *d, unsigned qi, uint16_t qsize)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return -1;

	struct virtq *q = &d->q[qi];

	wr(d, REG_QUEUE_SEL, qi);

	uint32_t max = rd(d, REG_QUEUE_NUM_MAX);

	if (max == 0)
		return -1;		/* device has no such queue */
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

	q->desc = (struct virtq_desc *)mem;
	q->avail = (volatile struct virtq_avail *)(mem + desc_sz);
	q->avail_ring = (uint16_t *)((char *)q->avail + sizeof(struct virtq_avail));
	q->used = (volatile struct virtq_used *)(mem + used_off);
	q->used_ring = (struct virtq_used_elem *)((char *)q->used + sizeof(struct virtq_used));
	q->qsize = qsize;
	q->last_used_idx = 0;

	/* every descriptor free, in a chain through next */
	for (uint16_t i = 0; i < qsize; i++)
		q->desc[i].next = (uint16_t)(i + 1);
	q->desc[qsize - 1].next = VIRTQ_NO_DESC;
	q->free_head = 0;
	q->nfree = qsize;

	wr(d, REG_QUEUE_PFN, (uint32_t)(mem / PAGE_SIZE));
	return 0;
}

void
virtio_dev_ready(struct virtio_dev *d)
{
	wr(d, REG_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);
}

int
virtio_dev_init(struct virtio_dev *d, uint16_t qsize)
{
	if (virtio_dev_begin(d, 0, 0) != 0)
		return -1;
	if (virtio_queue_init(d, 0, qsize) != 0)
		return -1;
	virtio_dev_ready(d);
	return 0;
}

int
virtio_desc_alloc(struct virtio_dev *d, unsigned qi)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return -1;

	struct virtq *q = &d->q[qi];

	if (q->free_head == VIRTQ_NO_DESC || q->nfree == 0)
		return -1;

	uint16_t i = q->free_head;

	q->free_head = q->desc[i].next;
	q->nfree--;
	return (int)i;
}

void
virtio_desc_free(struct virtio_dev *d, unsigned qi, uint16_t i)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return;

	struct virtq *q = &d->q[qi];

	if (i >= q->qsize)
		return;
	q->desc[i].next = q->free_head;
	q->free_head = i;
	q->nfree++;
}

void
virtio_desc_set(struct virtio_dev *d, unsigned qi, uint16_t i,
    const void *addr, uint32_t len, int writable, int next)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return;

	struct virtq *q = &d->q[qi];

	if (i >= q->qsize)
		return;
	q->desc[i].addr = (uint64_t)(uintptr_t)addr;
	q->desc[i].len = len;
	q->desc[i].flags = (uint16_t)((writable ? DESC_F_WRITE : 0) |
	    (next >= 0 ? DESC_F_NEXT : 0));
	q->desc[i].next = next >= 0 ? (uint16_t)next : 0;
}

void
virtio_submit(struct virtio_dev *d, unsigned qi, uint16_t head)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return;

	struct virtq *q = &d->q[qi];

	barrier();			/* desc(s) visible before avail */

	uint16_t idx = q->avail->idx;

	q->avail_ring[idx % q->qsize] = head;
	barrier();			/* ring entry before idx bump */
	q->avail->idx = idx + 1;
	barrier();			/* idx visible before notify */

	wr(d, REG_QUEUE_NOTIFY, qi);
}

int
virtio_poll_used(struct virtio_dev *d, unsigned qi, uint16_t *id, uint32_t *len)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return 0;

	struct virtq *q = &d->q[qi];

	if (q->used->idx == q->last_used_idx)
		return 0;

	barrier();			/* idx read before the element */

	struct virtq_used_elem *e = &q->used_ring[q->last_used_idx % q->qsize];

	if (id)
		*id = (uint16_t)e->id;
	if (len)
		*len = e->len;
	q->last_used_idx++;

	/* Acknowledging is the interrupt handler's job once a line is
	 * routed, and must not be done here as well.
	 *
	 * The device raises a level for every completion, and the ack is
	 * what lowers it. A poll that acks first lowers the level before
	 * the cpu ever takes the interrupt, so the handler simply never
	 * runs -- which showed up as the interrupt count being 1 or 0
	 * depending on whether the poll or the cpu won the race.
	 *
	 * With no line routed there is nothing to race, and the ack has to
	 * happen here or the level stays asserted forever.
	 */
	if (!d->irq_routed) {
		uint32_t is = rd(d, REG_INT_STATUS);

		if (is)
			wr(d, REG_INT_ACK, is);
	}
	return 1;
}

/* ---- interrupts ----
 *
 * One vector for every virtio device. The lines are level-triggered, so
 * the handler has to clear the source at the device that raised it, and
 * with a shared vector it does that by asking each registered device
 * whether it has anything pending. There are at most eight.
 */

#define VIRTIO_VECTOR 0x40	/* above the 32 architectural exceptions */

static struct virtio_dev *irq_devs[VIRTIO_NUM_SLOTS];
static volatile unsigned long irq_taken;

void virtio_isr(void);

void
virtio_isr(void)
{
	for (int i = 0; i < VIRTIO_NUM_SLOTS; i++) {
		struct virtio_dev *d = irq_devs[i];

		if (!d)
			continue;

		uint32_t is = rd(d, REG_INT_STATUS);

		if (is) {
			/* clears the level at the source. Without this the
			 * IOAPIC would re-raise the moment we return.
			 */
			wr(d, REG_INT_ACK, is);
			irq_taken++;
		}
	}
	lapic_eoi();
}

unsigned long
virtio_irq_count(void)
{
	return irq_taken;
}

void
virtio_irq_enable(struct virtio_dev *d)
{
	static int wired;

	if (d->slot < 0 || d->slot >= VIRTIO_NUM_SLOTS)
		return;
	if (irq_devs[d->slot] == d)
		return;			/* already routed */

	irq_devs[d->slot] = d;
	d->irq_routed = 1;	/* the handler owns the ack from here */

	if (!wired) {
		idt_set_vector(VIRTIO_VECTOR, isr_virtio);
		wired = 1;
	}
	ioapic_route(VIRTIO_MMIO_GSI_BASE + d->slot, VIRTIO_VECTOR);
}

/* submit a chain and busy-wait for it. Returns the byte count the
 * device reports writing, or -1.
 */
static int
kick_and_wait(struct virtio_dev *d, uint16_t head)
{
	virtio_submit(d, 0, head);

	uint16_t id;
	uint32_t len;

	while (!virtio_poll_used(d, 0, &id, &len))
		__asm__ volatile ("pause" ::: "memory");

	return (int)len;
}

int
virtio_submit_write_poll(struct virtio_dev *d, void *buf, uint32_t n)
{
	int i = virtio_desc_alloc(d, 0);

	if (i < 0)
		return -1;

	virtio_desc_set(d, 0, (uint16_t)i, buf, n, 1, -1);

	int got = kick_and_wait(d, (uint16_t)i);

	virtio_desc_free(d, 0, (uint16_t)i);
	return got;
}

int
virtio_submit_rpc_poll(struct virtio_dev *d, const void *req, uint32_t reqlen,
    void *rep, uint32_t repcap)
{
	int a = virtio_desc_alloc(d, 0);
	int b = virtio_desc_alloc(d, 0);

	if (a < 0 || b < 0) {
		if (a >= 0)
			virtio_desc_free(d, 0, (uint16_t)a);
		if (b >= 0)
			virtio_desc_free(d, 0, (uint16_t)b);
		return -1;
	}

	/* a (readable, the request) -> b (writable, the reply) */
	virtio_desc_set(d, 0, (uint16_t)a, req, reqlen, 0, b);
	virtio_desc_set(d, 0, (uint16_t)b, rep, repcap, 1, -1);

	int got = kick_and_wait(d, (uint16_t)a);

	virtio_desc_free(d, 0, (uint16_t)b);
	virtio_desc_free(d, 0, (uint16_t)a);
	return got;
}
