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

int
virtio_9p_rpc(const void *req, size_t reqlen, void *rep, size_t repcap)
{
	if (!p9_ready)
		return -1;
	if (reqlen > P9_MSIZE || repcap > P9_MSIZE)
		return -1;
	return virtio_submit_rpc_poll(&p9dev, req, (uint32_t)reqlen,
	    rep, (uint32_t)repcap);
}
