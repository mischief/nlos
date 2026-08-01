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
	if (virtio_dev_init(&p9dev, 8) != 0)
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

/* the transport owns both buffers, because the device reads one and
 * writes the other while the calling proc is descheduled -- neither can
 * be a pointer into a Lua state that may have moved or collected by
 * then.
 *
 * One request in flight. The 9p capability belongs to a single task
 * (PRIV_P9, lib/p9srv.lua), so contention means two of its threads, and
 * the binding yields and retries rather than failing.
 */
static char p9req[P9_MSIZE];
static char p9rep[P9_MSIZE];
static int p9_inflight;
static uint16_t p9_dreq, p9_drep;

int
virtio_9p_start(const void *req, size_t reqlen)
{
	if (!p9_ready || p9_inflight || reqlen > P9_MSIZE)
		return -1;

	int a = virtio_desc_alloc(&p9dev, 0);
	int b = virtio_desc_alloc(&p9dev, 0);

	if (a < 0 || b < 0) {
		if (a >= 0)
			virtio_desc_free(&p9dev, 0, (uint16_t)a);
		if (b >= 0)
			virtio_desc_free(&p9dev, 0, (uint16_t)b);
		return -1;
	}

	memcpy(p9req, req, reqlen);

	/* a readable (the T-message) chained to b writable (the R-message) */
	virtio_desc_set(&p9dev, 0, (uint16_t)a, p9req, (uint32_t)reqlen, 0, b);
	virtio_desc_set(&p9dev, 0, (uint16_t)b, p9rep, P9_MSIZE, 1, -1);

	p9_dreq = (uint16_t)a;
	p9_drep = (uint16_t)b;
	p9_inflight = 1;

	virtio_submit(&p9dev, 0, (uint16_t)a);
	return 0;
}

int
virtio_9p_poll(const void **rep)
{
	uint16_t id;
	uint32_t len;

	if (!p9_inflight)
		return -1;
	if (!virtio_poll_used(&p9dev, 0, &id, &len))
		return -1;

	virtio_desc_free(&p9dev, 0, p9_drep);
	virtio_desc_free(&p9dev, 0, p9_dreq);
	p9_inflight = 0;

	if (len > P9_MSIZE)
		len = P9_MSIZE;
	if (rep)
		*rep = p9rep;
	return (int)len;
}
