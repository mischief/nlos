/* virtio-9p: one device, one queue, request/reply over two chained
 * descriptors per call (see virtio_submit_rpc_poll). qemu's own
 * extension (hw/9pfs), not in the official virtio spec -- VIRTIO_ID_9P
 * = 9, config space is a u16 mount-tag length followed by the tag
 * bytes (no fixed-size struct, so read as raw bytes rather than
 * through the 32-bit register accessors virtio.c uses elsewhere).
 */

#include <stdint.h>
#include <string.h>

#include "microvm.h"
#include "virtio.h"
#include "virtio_9p.h"

#define VIRTIO_ID_9P 9
#define CONFIG_OFF   0x100

/* msize (see lib/ninep.lua's M.MSIZE): the largest 9P message either
 * side will send. one page is plenty of queue depth for two
 * descriptors; the buffers themselves are sized to this.
 */
#define P9_MSIZE 8192

static struct virtio_dev p9dev;
static int p9_ready;

int
virtio_9p_init(void)
{
	if (virtio_find(VIRTIO_ID_9P, &p9dev) != 0)
		return -1;
	if (virtio_dev_init(&p9dev, 2 * VIRTIO_9P_SLOTS) != 0)
		return -1;
	p9_ready = 1;
	return 0;
}

int
virtio_9p_tag(char *buf, size_t bufcap)
{
	if (!p9_ready)
		return -1;

	volatile uint8_t *cfg = (volatile uint8_t *)p9dev.regs + CONFIG_OFF;
	uint16_t len = cfg[0] | ((uint16_t)cfg[1] << 8);

	if ((size_t)len >= bufcap)
		return -1;
	for (uint16_t i = 0; i < len; i++)
		buf[i] = (char)cfg[2 + i];
	buf[len] = '\0';
	return len;
}

/* the transport owns the buffers, because the device reads one and
 * writes the other while the calling proc is descheduled -- neither can
 * be a pointer into a Lua state that may have moved or collected by
 * then.
 *
 * One set per slot, so slots are independent: that is what lets a
 * second request start before the first has answered. The cost is
 * static and paid whether or not the depth is used -- 8 slots at two
 * 8K buffers is 128K, against a machine with 256M.
 *
 * The queue is sized to match. Each slot holds two descriptors for as
 * long as it is busy, so a queue shorter than 2 * VIRTIO_9P_SLOTS would
 * make virtio_desc_alloc the real limit and the slot table a lie about
 * the depth. virtio_queue_init clamps to what the device offers, and
 * the code below copes with a smaller queue by simply failing to start
 * -- which start's contract already allows for.
 */
static char p9req[VIRTIO_9P_SLOTS][P9_MSIZE];
static char p9rep[VIRTIO_9P_SLOTS][P9_MSIZE];

static struct {
	int busy;		/* started, not yet reaped */
	int done;		/* the device has answered; len is valid */
	uint32_t len;
	uint16_t dreq, drep;
} p9slot[VIRTIO_9P_SLOTS];

/* drain the used ring into the slots it belongs to.
 *
 * Completions are per device, not per slot: the ring says which
 * descriptor chain finished, in whatever order the device chose, and
 * any poll may be the one that sees a reply meant for another slot.
 * So every poll drains everything and files each result under its own
 * slot, rather than looking only for its own and dropping the rest --
 * which would lose completions outright, since virtio_poll_used
 * consumes the entry it reports.
 */
static void
reap(void)
{
	uint16_t id;
	uint32_t len;

	while (virtio_poll_used(&p9dev, 0, &id, &len)) {
		for (int i = 0; i < VIRTIO_9P_SLOTS; i++) {
			if (!p9slot[i].busy || p9slot[i].done)
				continue;
			if (p9slot[i].dreq != id)
				continue;

			p9slot[i].len = len > P9_MSIZE ? P9_MSIZE : len;
			p9slot[i].done = 1;
			break;
		}
	}
}

int
virtio_9p_start(const void *req, size_t reqlen)
{
	int slot = -1;

	if (!p9_ready || reqlen > P9_MSIZE)
		return -1;

	for (int i = 0; i < VIRTIO_9P_SLOTS; i++) {
		if (!p9slot[i].busy) {
			slot = i;
			break;
		}
	}
	if (slot < 0)
		return -1;		/* window full; the caller retries */

	int a = virtio_desc_alloc(&p9dev, 0);
	int b = virtio_desc_alloc(&p9dev, 0);

	if (a < 0 || b < 0) {
		if (a >= 0)
			virtio_desc_free(&p9dev, 0, (uint16_t)a);
		if (b >= 0)
			virtio_desc_free(&p9dev, 0, (uint16_t)b);
		return -1;
	}

	memcpy(p9req[slot], req, reqlen);

	/* a readable (the T-message) chained to b writable (the R-message) */
	virtio_desc_set(&p9dev, 0, (uint16_t)a, p9req[slot], (uint32_t)reqlen, 0, b);
	virtio_desc_set(&p9dev, 0, (uint16_t)b, p9rep[slot], P9_MSIZE, 1, -1);

	p9slot[slot].dreq = (uint16_t)a;
	p9slot[slot].drep = (uint16_t)b;
	p9slot[slot].busy = 1;
	p9slot[slot].done = 0;
	p9slot[slot].len = 0;

	virtio_submit(&p9dev, 0, (uint16_t)a);
	return slot;
}

int
virtio_9p_poll(int slot, const void **rep)
{
	if (slot < 0 || slot >= VIRTIO_9P_SLOTS || !p9slot[slot].busy)
		return -1;

	if (!p9slot[slot].done) {
		reap();
		if (!p9slot[slot].done)
			return -1;
	}

	virtio_desc_free(&p9dev, 0, p9slot[slot].drep);
	virtio_desc_free(&p9dev, 0, p9slot[slot].dreq);
	p9slot[slot].busy = 0;
	p9slot[slot].done = 0;

	if (rep)
		*rep = p9rep[slot];
	return (int)p9slot[slot].len;
}
