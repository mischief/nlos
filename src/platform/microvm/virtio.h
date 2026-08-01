#ifndef MICROVM_VIRTIO_H
#define MICROVM_VIRTIO_H

#include <stddef.h>
#include <stdint.h>

/* legacy (version 1) virtio-mmio: one virtqueue in a single contiguous,
 * page-aligned allocation (desc table, avail ring, padding to
 * queue_align, used ring), addressed by physical page number --
 * qemu's virtio-mmio defaults to force-legacy=true, and microvm never
 * overrides that (see hw/i386/virtio-mmio.c, hw/i386/microvm.c), so
 * this is the only mode microvm guests ever see.
 */
struct virtq_desc {
	uint64_t addr;
	uint32_t len;
	uint16_t flags;
	uint16_t next;
};

struct virtq_avail {
	uint16_t flags;
	uint16_t idx;
	/* ring[qsize], then used_event -- addressed separately below */
};

struct virtq_used_elem {
	uint32_t id;
	uint32_t len;
};

struct virtq_used {
	uint16_t flags;
	uint16_t idx;
	/* ring[qsize], then avail_event */
};

struct virtio_dev {
	volatile uint32_t *regs;
	struct virtq_desc *desc;
	volatile struct virtq_avail *avail;
	uint16_t *avail_ring;
	volatile struct virtq_used *used;
	struct virtq_used_elem *used_ring;
	uint16_t qsize;
	uint16_t last_used_idx;
};

/* scans the 8 fixed microvm virtio-mmio slots (0xfeb00000 + i*512, see
 * qemu's include/hw/i386/microvm.h) for one matching device_id. 0 and
 * fills *out, -1 if none present.
 */
int	virtio_find(uint32_t device_id, struct virtio_dev *out);

/* status/feature negotiation (accepts no optional features) plus
 * queue 0 setup at the given size (clamped to QUEUE_NUM_MAX). must be
 * called before any submit. 0 on success.
 */
int	virtio_dev_init(struct virtio_dev *d, uint16_t qsize);

/* submits one device-writable descriptor spanning buf[0,n), kicks the
 * device, and busy-waits for it to land in the used ring. returns the
 * byte count the device actually wrote, or -1.
 *
 * synchronous and single-outstanding-request by design: fine for a
 * driver whose only client is a blocking Lua call (los.platform.rng),
 * not a template for a queue with real concurrency.
 */
int	virtio_submit_write_poll(struct virtio_dev *d, void *buf, uint32_t n);

/* two-descriptor request/reply, chained: descriptor 0 is
 * device-readable over req[0,reqlen) (the outgoing message),
 * descriptor 1 is device-writable over rep[0,repcap) (where the
 * device puts its reply). kicks and busy-waits like
 * virtio_submit_write_poll; returns the reply length actually written,
 * or -1. shape matches virtio-9p (one T-message in, one R-message
 * out) but isn't 9p-specific -- any request/reply virtio-mmio device
 * fits this.
 */
int	virtio_submit_rpc_poll(struct virtio_dev *d, const void *req,
	    uint32_t reqlen, void *rep, uint32_t repcap);

#endif
