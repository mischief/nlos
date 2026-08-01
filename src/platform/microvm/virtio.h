#ifndef MICROVM_VIRTIO_H
#define MICROVM_VIRTIO_H

#include <stddef.h>
#include <stdint.h>

/* legacy (version 1) virtio-mmio: each virtqueue in a single contiguous,
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

/* rng and 9p each need one queue; net needs two (0 receive, 1 transmit).
 * Raising this costs only the inline array below.
 */
#define VIRTIO_MAX_QUEUES 2

#define VIRTQ_NO_DESC 0xffff

struct virtq {
	struct virtq_desc *desc;
	volatile struct virtq_avail *avail;
	uint16_t *avail_ring;
	volatile struct virtq_used *used;
	struct virtq_used_elem *used_ring;
	uint16_t qsize;
	uint16_t last_used_idx;

	/* unused descriptors, threaded through desc[].next. A queue with
	 * several requests outstanding -- which a receive queue always has,
	 * since buffers are posted before anything arrives -- cannot use
	 * fixed indices the way a synchronous one can.
	 */
	uint16_t free_head;
	uint16_t nfree;
};

struct virtio_dev {
	volatile uint32_t *regs;
	struct virtq q[VIRTIO_MAX_QUEUES];
};

/* scans the 8 fixed microvm virtio-mmio slots (0xfeb00000 + i*512, see
 * qemu's include/hw/i386/microvm.h) for one matching device_id. 0 and
 * fills *out, -1 if none present.
 */
int	virtio_find(uint32_t device_id, struct virtio_dev *out);

/* ---- setup, in three steps ----
 *
 * The order is the specification's and is not negotiable: reset,
 * acknowledge, negotiate features, configure queues, then DRIVER_OK.
 * A device may not be used before the last step, and queues may not be
 * configured after it.
 */

/* reset, acknowledge, and negotiate. `want` is the feature bits to
 * request from word 0; *got, if non-null, receives what the device
 * actually offered of them. Asking for a bit the device lacks is not an
 * error -- the caller decides whether it can live without it.
 */
int	virtio_dev_begin(struct virtio_dev *d, uint32_t want, uint32_t *got);

/* configure queue `qi` at up to `qsize` entries (clamped to the
 * device's maximum). Must follow virtio_dev_begin and precede
 * virtio_dev_ready.
 */
int	virtio_queue_init(struct virtio_dev *d, unsigned qi, uint16_t qsize);

void	virtio_dev_ready(struct virtio_dev *d);

/* begin(no features) + queue 0 + ready, which is every device here that
 * wants one queue and no features.
 */
int	virtio_dev_init(struct virtio_dev *d, uint16_t qsize);

/* ---- descriptors ----
 *
 * A caller building its own chains manages descriptors explicitly. The
 * synchronous helpers below do this internally.
 */

/* an index, or -1 when the queue is full */
int	virtio_desc_alloc(struct virtio_dev *d, unsigned qi);
void	virtio_desc_free(struct virtio_dev *d, unsigned qi, uint16_t i);

/* fill descriptor `i`. writable means the DEVICE writes it (a receive
 * buffer, or a reply); next < 0 ends the chain.
 */
void	virtio_desc_set(struct virtio_dev *d, unsigned qi, uint16_t i,
	    const void *addr, uint32_t len, int writable, int next);

/* publish `head` on the avail ring and notify the device. Returns
 * without waiting -- pair with virtio_poll_used.
 */
void	virtio_submit(struct virtio_dev *d, unsigned qi, uint16_t head);

/* non-blocking completion check. 1 and fills *id (the chain head) and
 * *len (bytes the device wrote) when something completed, else 0. The
 * caller owns the descriptors again and must free them.
 */
int	virtio_poll_used(struct virtio_dev *d, unsigned qi, uint16_t *id,
	    uint32_t *len);

/* ---- synchronous helpers ----
 *
 * One request in flight, busy-waited. Right for a driver whose only
 * client is a blocking Lua call (los.platform.rng, virtio-9p); wrong
 * for anything that receives unsolicited traffic, which is what the
 * primitives above are for.
 */

/* one device-writable descriptor over buf[0,n). Returns the byte count
 * the device wrote, or -1.
 */
int	virtio_submit_write_poll(struct virtio_dev *d, void *buf, uint32_t n);

/* two chained descriptors: req[0,reqlen) device-readable, rep[0,repcap)
 * device-writable. Returns the reply length, or -1. The shape matches
 * virtio-9p (one T-message in, one R-message out) but is not 9p
 * specific -- any request/reply virtio-mmio device fits it.
 */
int	virtio_submit_rpc_poll(struct virtio_dev *d, const void *req,
	    uint32_t reqlen, void *rep, uint32_t repcap);

#endif
