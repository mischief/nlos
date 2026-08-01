/* virtio-rng: one device, one queue, one descriptor reused for every
 * request -- see virtio.c for why that's an acceptable shape here
 * (single synchronous caller, los.platform.rng.bytes).
 */

#include <stdint.h>

#include "microvm.h"
#include "virtio.h"
#include "virtio_rng.h"

#define VIRTIO_ID_RNG 4

static struct virtio_dev rngdev;
static int rng_ready;

int
virtio_rng_init(void)
{
	if (virtio_find(VIRTIO_ID_RNG, &rngdev) != 0)
		return -1;
	if (virtio_dev_init(&rngdev, 8) != 0)
		return -1;
	rng_ready = 1;
	return 0;
}

int
virtio_rng_read(void *buf, size_t n)
{
	if (!rng_ready)
		return -1;
	return virtio_submit_write_poll(&rngdev, buf, (uint32_t)n);
}
