/* virtio core: legacy queue setup, descriptor allocation, and both a
 * synchronous and an asynchronous submit path. See virtio.h.
 *
 * Everything here is transport-independent. How a device's registers
 * are reached -- memory-mapped in qemu's microvm window, or an IO BAR
 * on a PCI bus under OpenBSD vmd -- is virtio_mmio.c and virtio_pci.c,
 * behind struct virtio_transport. The rings are identical either way:
 * both machines speak the legacy layout, one contiguous page-aligned
 * desc/avail/used allocation addressed by page number.
 */

#include <string.h>

#include "microvm.h"
#include "virtio.h"

#define STATUS_ACK          0x01
#define STATUS_DRIVER       0x02
#define STATUS_DRIVER_OK    0x04
#define STATUS_FEATURES_OK  0x08
#define STATUS_FAILED       0x80

#define DESC_F_NEXT  1
#define DESC_F_WRITE 2

#define PAGE_SIZE 4096

/* the compiler must not move descriptor or ring writes across these:
 * the device reads the same memory concurrently. On x86 the hardware
 * ordering is already strong enough, so a compiler barrier is the whole
 * requirement here.
 */
#define barrier() __asm__ volatile ("" ::: "memory")

static size_t
align_up(size_t n, size_t a)
{
	return (n + (a - 1)) & ~(a - 1);
}

uint8_t
virtio_config8(struct virtio_dev *d, unsigned off)
{
	return d->t->config8(d, off);
}

/* which transport to look on, decided by whether the machine has a PCI
 * bus at all.
 *
 * Not "try one, then the other": the mmio window cannot be probed on a
 * machine that has PCI. 0xfeb00000 lies inside the range vmd declares
 * VM_MEM_MMIO, and reading an address no emulated device claims
 * terminates the guest outright -- no trap, nothing logged. So the bus
 * has to be ruled out before the first load, not after. See pci.c.
 */
int
virtio_find(uint32_t device_id, struct virtio_dev *out)
{
	if (pci_present())
		return virtio_pci_find(device_id, out);
	return virtio_mmio_find(device_id, out);
}

/* the specification's initialization sequence (virtio 1.3, 3.1.1), which
 * is the same eight steps on both transports -- reset, ACKNOWLEDGE,
 * DRIVER, negotiate, FEATURES_OK, re-read, queues, DRIVER_OK -- with
 * one difference: steps 5 and 6 are virtio-1.0 steps, and a legacy
 * device has no FEATURES_OK bit to set. Which of the two this is falls
 * out of the negotiation itself rather than being asked separately: if
 * VERSION_1 ended up in the accepted set, the modern rules apply.
 */
int
virtio_dev_begin(struct virtio_dev *d, uint64_t want, uint64_t *got)
{
	d->t->set_status(d, 0);				/* reset */
	d->t->set_status(d, STATUS_ACK);
	d->t->set_status(d, STATUS_ACK | STATUS_DRIVER);

	uint64_t offered = d->t->get_features(d);
	uint64_t need = d->t->required_features;

	/* a transport that cannot work without a bit the device does not
	 * offer has nothing to fall back to, and saying so here is better
	 * than failing later in a queue setup that cannot work.
	 */
	if ((offered & need) != need) {
		d->t->set_status(d, STATUS_FAILED);
		return -1;
	}

	uint64_t accept = (offered & want) | need;

	d->t->set_features(d, accept);
	d->features = accept;

	if (got)
		*got = accept;

	if (!(accept & VIRTIO_F_VERSION_1))
		return 0;			/* legacy: no such handshake */

	d->t->set_status(d, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);

	/* step 6, and it is a real check rather than a formality: the
	 * device clears this bit to say it cannot live with the subset we
	 * chose, and it is the only way it can say so.
	 */
	if (!(d->t->get_status(d) & STATUS_FEATURES_OK)) {
		d->t->set_status(d, STATUS_FAILED);
		return -1;
	}
	return 0;
}

int
virtio_queue_init(struct virtio_dev *d, unsigned qi, uint16_t qsize)
{
	if (qi >= VIRTIO_MAX_QUEUES)
		return -1;

	struct virtq *q = &d->q[qi];

	uint16_t max = d->t->queue_max(d, qi);

	if (max == 0)
		return -1;		/* device has no such queue */
	if (qsize > max)
		qsize = max;

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

	d->t->queue_setup(d, qi, qsize, (uint64_t)mem,
	    (uint64_t)(mem + desc_sz), (uint64_t)(mem + used_off));
	return 0;
}

void
virtio_dev_ready(struct virtio_dev *d)
{
	uint8_t status = STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK;

	/* FEATURES_OK has to stay set once it is set: the status register
	 * is written whole, so dropping it here would read to the device
	 * as the driver withdrawing it.
	 */
	if (d->features & VIRTIO_F_VERSION_1)
		status |= STATUS_FEATURES_OK;

	/* the last thing before DRIVER_OK, because it is the last thing
	 * the specification allows: a queue's vector is part of its
	 * configuration, and configuration closes here. Every queue that
	 * was set up gets it -- one that was not has no rings and cannot
	 * raise anything.
	 */
	unsigned nq = 0;

	while (nq < VIRTIO_MAX_QUEUES && d->q[nq].desc != 0)
		nq++;
	virtio_pci_msix_arm(d, nq);

	d->t->set_status(d, status);
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

	d->t->notify(d, qi);
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
	if (!d->irq_routed)
		d->t->isr_ack(d);
	return 1;
}

/* ---- interrupts ----
 *
 * One handler for every virtio device. The lines are level-triggered
 * (and shared, on a PCI machine), so the handler has to clear the
 * source at the device that raised it, and it does that by asking each
 * registered device whether it has anything pending. There are few.
 */

static struct virtio_dev *irq_devs[VIRTIO_MAX_DEVS];
static int irq_last_gsi = -1;
static int irq_msi;
static volatile unsigned long irq_taken;

void virtio_isr(void);

void
virtio_isr(void)
{
	int claimed = 0;

	for (int i = 0; i < VIRTIO_MAX_DEVS; i++) {
		struct virtio_dev *d = irq_devs[i];

		if (!d)
			continue;

		/* a message-signalled device has nothing to clear: the
		 * message was the whole event, and the specification leaves
		 * its ISR byte unused (4.1.4.5) -- reading it would answer
		 * zero forever and mean nothing.
		 */
		if (d->msix_vector > 0)
			continue;

		/* reading is also the acknowledgement on PCI, so this asks
		 * once and acts on the answer -- clearing the level at the
		 * source, without which the controller re-raises the moment
		 * we return.
		 */
		if (d->t->isr_ack(d)) {
			irq_taken++;
			claimed = 1;
		}
	}

	/* an interrupt no line-driven device owned came from a message,
	 * and there is exactly one such delivery per interrupt however
	 * many devices are registered.
	 */
	if (!claimed && irq_msi)
		irq_taken++;

	/* the line to end, which is whichever was routed last: with one
	 * device per line and a shared handler there is no way to tell
	 * from here which of them the controller delivered, and a
	 * non-specific EOI is what both controllers want anyway. A message
	 * has no line at all, and ends at the LAPIC.
	 */
	if (irq_last_gsi >= 0)
		intr_eoi(irq_last_gsi);
	else if (irq_msi)
		intr_eoi_msi();
}

/* claim a vector for messages from a device that has just been found.
 *
 * At discovery, and not when a driver enables interrupts, because the
 * device is armed the moment its MSI-X table entry is written: a
 * polling driver that never enables anything still has a device that
 * can raise, and the first message would land on a vector with no
 * handler -- which the idt reports as a trap and the guest does not
 * survive. Installing it early costs one idt slot and an end-of-
 * interrupt nobody needed.
 */
void
virtio_msi_route(int vector)
{
	irq_msi = 1;
	intr_route_msi(vector, isr_virtio);
}

unsigned long
virtio_irq_count(void)
{
	return irq_taken;
}

void
virtio_irq_enable(struct virtio_dev *d)
{
	int slot = -1;

	for (int i = 0; i < VIRTIO_MAX_DEVS; i++) {
		if (irq_devs[i] == d)
			return;			/* already routed */
		if (irq_devs[i] == 0 && slot < 0)
			slot = i;
	}
	if (slot < 0)
		return;

	irq_devs[slot] = d;
	d->irq_routed = 1;	/* the handler owns the ack from here */

	/* a message-signalled device needs nothing routed here: its vector
	 * was installed when it was found, because a message can arrive
	 * before any driver asks for one and a vector with no handler is
	 * a fatal trap. Registering it is still worth doing -- that is
	 * what the ack loop walks -- but there is no line to unmask and
	 * none to end at. See virtio_isr for the other half.
	 */
	if (d->msix_vector > 0)
		return;

	irq_last_gsi = d->gsi;

	/* the transport worked out the line: a slot's position in the mmio
	 * window fixes it there, config space names it on PCI.
	 */
	intr_route(d->gsi, isr_virtio);
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
