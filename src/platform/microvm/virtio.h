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

/* how many devices may have their interrupt routed at once. The mmio
 * window has eight slots and a PCI machine here has fewer devices than
 * that, so eight covers both.
 */
#define VIRTIO_MAX_DEVS 8

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

struct virtio_dev;

/* how to reach a device's registers, which is the only thing that
 * differs between the two machines this platform runs on.
 *
 * qemu's microvm has virtio-mmio: registers memory-mapped in a fixed
 * window, 32 bits wide, one page-ish slot per device. OpenBSD vmd has
 * legacy virtio-PCI: the same registers, semantically, in an IO BAR at
 * different offsets and mixed widths (usr.sbin/vmd/virtio.c against
 * sys/dev/pci/virtio_pcireg.h's "Virtio 0.9 config space").
 *
 * The split is at what the registers MEAN, not where they are, because
 * offsets are not the whole difference: legacy PCI has no
 * guest-page-size or queue-align register (both are implicitly 4096)
 * and its queue size and notify are 16-bit while mmio's are 32. A
 * register-address mapping would have to lie about all of that; an
 * operation does not.
 *
 * Everything above this line -- the rings, the descriptors, the setup
 * order, the polling -- is identical on both and lives in virtio.c.
 */
struct virtio_transport {
	const char *name;

	/* what this transport cannot work without, which the negotiation
	 * in virtio.c must therefore secure or give up. Zero on legacy
	 * mmio; VIRTIO_F_VERSION_1 on a modern PCI device, which by
	 * definition has no legacy interface to fall back to.
	 */
	uint64_t required_features;

	uint64_t (*get_features)(struct virtio_dev *d);
	void	(*set_features)(struct virtio_dev *d, uint64_t v);
	void	(*set_status)(struct virtio_dev *d, uint8_t status);
	uint8_t	(*get_status)(struct virtio_dev *d);
	uint16_t (*queue_max)(struct virtio_dev *d, unsigned qi);

	/* select the queue, size it, and hand over its rings.
	 *
	 * Three addresses rather than the one page number legacy uses:
	 * that is what virtio 1.0 asks for, and the legacy side can
	 * recover its page number from the first of them, since the three
	 * are contiguous in one allocation either way. The reverse is not
	 * true, which is why the interface is shaped this way round.
	 */
	void	(*queue_setup)(struct virtio_dev *d, unsigned qi,
		    uint16_t qsize, uint64_t desc, uint64_t avail,
		    uint64_t used);

	void	(*notify)(struct virtio_dev *d, unsigned qi);

	/* read the interrupt status and acknowledge it in one go: mmio
	 * needs two registers for that and PCI clears on read.
	 */
	uint32_t (*isr_ack)(struct virtio_dev *d);
	uint8_t	(*config8)(struct virtio_dev *d, unsigned off);
};

/* bit 32, so everything touching features has to be 64 bits wide. This
 * is the bit that says "not the legacy interface".
 */
#define VIRTIO_F_VERSION_1 (1ULL << 32)

struct virtio_dev {
	const struct virtio_transport *t;
	volatile uint32_t *regs;	/* mmio: the register window */

	/* pci: the IO BAR, and where in it each virtio structure the
	 * capability list pointed at begins. See virtio_pci.c.
	 */
	uint16_t iobase;
	uint16_t cfg_common;
	uint16_t cfg_notify;
	uint16_t cfg_isr;
	uint16_t cfg_device;
	uint32_t notify_mul;

	struct virtq q[VIRTIO_MAX_QUEUES];
	int slot;		/* mmio: which slot, which fixes its gsi */
	int gsi;		/* the line this device raises */
	int irq_routed;		/* set by virtio_irq_enable; see the ack rule */
	uint64_t features;	/* what negotiation actually settled on */
};

/* find a device of this virtio type on whichever transport the machine
 * has. 0 and fills *out, -1 if none present. `device_id` is the virtio
 * device type (1 net, 4 rng, 9 9p), not a bus id -- PCI spells those
 * 0x1040 + type, and this is the layer that knows it.
 */
int	virtio_find(uint32_t device_id, struct virtio_dev *out);

/* the per-transport halves of that search, each returning 0 and filling
 * *out with its own ops attached. virtio_mmio.c and virtio_pci.c.
 */
int	virtio_mmio_find(uint32_t device_id, struct virtio_dev *out);
int	virtio_pci_find(uint32_t device_id, struct virtio_dev *out);

/* one device-config byte, whatever the transport. Drivers read their
 * config space (a mac address, a mount tag length) through this rather
 * than off d->regs, which only one of the two transports has.
 */
uint8_t	virtio_config8(struct virtio_dev *d, unsigned off);

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
int	virtio_dev_begin(struct virtio_dev *d, uint64_t want, uint64_t *got);

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

/* ---- interrupts ----
 *
 * Route this device's line to the shared virtio vector and unmask it.
 * All virtio devices share one vector: the lines are level-triggered,
 * so the handler has to clear the source at the device anyway, and
 * walking the few registered devices is cheaper than eight vectors and
 * eight stubs.
 *
 * Enabling this does not change how a driver reads completions --
 * virtio_poll_used is still the way. What it buys is that the machine
 * can stop spinning: an idle cpu can halt and be woken, instead of
 * looping over queues that have nothing in them.
 */
void	virtio_irq_enable(struct virtio_dev *d);

/* how many virtio interrupts have been taken. A counter rather than a
 * callback because the handler runs with a proc interrupted and must
 * not touch the scheduler.
 */
unsigned long virtio_irq_count(void);

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
