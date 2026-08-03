/* virtio-blk: one device, one queue, three descriptors per request --
 * a device-readable 16-byte header, the data (either direction), and a
 * device-writable status byte. VIRTIO_ID_BLOCK = 2; config space
 * begins with a u64 capacity in 512-byte sectors.
 *
 * The shape is virtio_9p.c's: a slot table, start/poll rather than a
 * busy-wait, and a reap that drains the whole used ring. The reasons
 * are the same ones and are written out there. What differs is only
 * that a block request is three descriptors instead of two, and that
 * the direction of the middle one is not fixed.
 *
 * No features are negotiated, which among other things means no
 * VIRTIO_BLK_F_FLUSH: there is no way to ask this device to commit, so
 * a write is durable when the device says it is and not before. That is
 * a real limitation and the reason to negotiate FLUSH is the first
 * thing to want here; it is left out only to keep the first cut to the
 * mechanism.
 */

#include <stdint.h>
#include <string.h>

#include "microvm.h"
#include "virtio.h"
#include "virtio_blk.h"

#define VIRTIO_ID_BLOCK 2

#define VIRTIO_BLK_T_IN  0	/* device -> guest */
#define VIRTIO_BLK_T_OUT 1	/* guest -> device */

/* three descriptors per slot, so a queue shorter than 3 *
 * VIRTIO_BLK_SLOTS would make virtio_desc_alloc the real limit and the
 * slot table a lie about the depth -- the same trap virtio_9p.c names.
 * Rounded up to a power of two because devices report their maximum as
 * one and clamping downwards is tidier from one.
 */
#define BLK_QSIZE (4 * VIRTIO_BLK_SLOTS)

struct blk_hdr {
	uint32_t type;
	uint32_t reserved;
	uint64_t sector;
};

static struct virtio_dev blkdev;
static int blk_ready;
static uint64_t blk_sectors;

/* the transport owns these, because the device reads or writes them
 * while the calling proc is descheduled -- see virtio_9p.c's comment on
 * the same point. One set per slot is what makes slots independent.
 */
static struct blk_hdr blkhdr[VIRTIO_BLK_SLOTS];
static uint8_t blkstatus[VIRTIO_BLK_SLOTS];
static uint8_t blkbuf[VIRTIO_BLK_SLOTS][VIRTIO_BLK_MAXIO];

static struct {
	int busy;		/* started, not yet reaped */
	int done;		/* the device has answered */
	uint32_t len;		/* bytes of data the request asked for */
	uint16_t d0, d1, d2;	/* header, data, status */
} blkslot[VIRTIO_BLK_SLOTS];

int
virtio_blk_init(void)
{
	if (virtio_find(VIRTIO_ID_BLOCK, &blkdev) != 0)
		return -1;
	if (virtio_dev_init(&blkdev, BLK_QSIZE) != 0)
		return -1;

	/* capacity is a u64 at config offset 0. Assembled a byte at a
	 * time because virtio_config8 is the only accessor both
	 * transports have -- the 32-bit register reads elsewhere in this
	 * platform are mmio-only.
	 */
	blk_sectors = 0;
	for (unsigned i = 0; i < 8; i++)
		blk_sectors |= (uint64_t)virtio_config8(&blkdev, i) << (8 * i);

	blk_ready = 1;
	return 0;
}

int
virtio_blk_present(void)
{
	return blk_ready;
}

uint64_t
virtio_blk_capacity(void)
{
	return blk_ready ? blk_sectors : 0;
}

/* drain the used ring into the slots it belongs to. Completions are per
 * device and may arrive in any order, and virtio_poll_used consumes the
 * entry it reports -- so a slot that looked only for its own head would
 * drop everybody else's. See virtio_9p.c's reap, which this is.
 */
static void
reap(void)
{
	uint16_t id;
	uint32_t len;

	while (virtio_poll_used(&blkdev, 0, &id, &len)) {
		for (int i = 0; i < VIRTIO_BLK_SLOTS; i++) {
			if (!blkslot[i].busy || blkslot[i].done)
				continue;
			if (blkslot[i].d0 != id)
				continue;

			/* the used-ring length is not the data length: it
			 * counts the status byte too, and devices differ on
			 * whether they count the data at all on a write. The
			 * request already knows how many bytes it asked for
			 * and the status byte says whether it got them, so
			 * len is deliberately not consulted here.
			 */
			blkslot[i].done = 1;
			break;
		}
	}
}

static void
slot_free(int slot)
{
	virtio_desc_free(&blkdev, 0, blkslot[slot].d2);
	virtio_desc_free(&blkdev, 0, blkslot[slot].d1);
	virtio_desc_free(&blkdev, 0, blkslot[slot].d0);
	blkslot[slot].busy = 0;
	blkslot[slot].done = 0;
}

int
virtio_blk_start(int write, uint64_t lba, const void *src, uint32_t len)
{
	int slot = -1;

	if (!blk_ready || len == 0 || len > VIRTIO_BLK_MAXIO)
		return -1;
	if (len % VIRTIO_BLK_SECTOR != 0)
		return -1;
	if (write && src == 0)
		return -1;

	/* refuse to address past the end rather than letting the device
	 * decide: a request that runs off the disk comes back as a bare
	 * IOERR with nothing to say which of several outstanding requests
	 * was the bad one.
	 */
	if (lba > blk_sectors || len / VIRTIO_BLK_SECTOR > blk_sectors - lba)
		return -1;

	for (int i = 0; i < VIRTIO_BLK_SLOTS; i++) {
		if (!blkslot[i].busy) {
			slot = i;
			break;
		}
	}
	if (slot < 0)
		return -1;		/* window full; the caller retries */

	int a = virtio_desc_alloc(&blkdev, 0);
	int b = virtio_desc_alloc(&blkdev, 0);
	int c = virtio_desc_alloc(&blkdev, 0);

	if (a < 0 || b < 0 || c < 0) {
		if (a >= 0)
			virtio_desc_free(&blkdev, 0, (uint16_t)a);
		if (b >= 0)
			virtio_desc_free(&blkdev, 0, (uint16_t)b);
		if (c >= 0)
			virtio_desc_free(&blkdev, 0, (uint16_t)c);
		return -1;
	}

	blkhdr[slot].type = write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN;
	blkhdr[slot].reserved = 0;
	blkhdr[slot].sector = lba;

	if (write)
		memcpy(blkbuf[slot], src, len);

	/* a readable (the header) -> b, whose direction IS the request ->
	 * c writable (the status byte the device reports through)
	 */
	virtio_desc_set(&blkdev, 0, (uint16_t)a, &blkhdr[slot],
	    (uint32_t)sizeof blkhdr[slot], 0, b);
	virtio_desc_set(&blkdev, 0, (uint16_t)b, blkbuf[slot], len,
	    write ? 0 : 1, c);
	virtio_desc_set(&blkdev, 0, (uint16_t)c, &blkstatus[slot], 1, 1, -1);

	/* not a valid status, so a device that never wrote one is
	 * distinguishable from one that answered OK
	 */
	blkstatus[slot] = 0xff;

	blkslot[slot].d0 = (uint16_t)a;
	blkslot[slot].d1 = (uint16_t)b;
	blkslot[slot].d2 = (uint16_t)c;
	blkslot[slot].busy = 1;
	blkslot[slot].done = 0;
	blkslot[slot].len = len;

	virtio_submit(&blkdev, 0, (uint16_t)a);
	return slot;
}

int
virtio_blk_poll(int slot, const void **data, uint32_t *len)
{
	if (slot < 0 || slot >= VIRTIO_BLK_SLOTS || !blkslot[slot].busy)
		return -1;

	if (!blkslot[slot].done) {
		reap();
		if (!blkslot[slot].done)
			return -1;
	}

	int status = blkstatus[slot];
	uint32_t n = blkslot[slot].len;

	slot_free(slot);

	if (status != 0)
		return status;

	if (data)
		*data = blkbuf[slot];
	if (len)
		*len = n;
	return 0;
}
