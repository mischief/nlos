#ifndef MICROVM_VIRTIO_BLK_H
#define MICROVM_VIRTIO_BLK_H

#include <stddef.h>
#include <stdint.h>

/* how many requests may be in flight at once. Same reasoning as
 * VIRTIO_9P_SLOTS: the depth is what lets a second reader start before
 * the first has answered, and lib/srv.lua's worker count is matched to
 * it (see task/blksrv.lua).
 */
#define VIRTIO_BLK_SLOTS 8

/* the largest single transfer, and therefore the per-slot buffer size.
 * 64K is 128 sectors -- comfortably more than any one dev read asks
 * for, and the static cost (8 slots x 64K = 512K, against a machine
 * with 256M) is the same trade virtio_9p.c already makes.
 */
#define VIRTIO_BLK_MAXIO 65536

/* the unit the capacity register counts in, and the unit lba is in.
 * Fixed at 512 by the specification regardless of what the device's
 * physical sectors are -- VIRTIO_BLK_F_BLK_SIZE reports the latter and
 * does not change the former.
 */
#define VIRTIO_BLK_SECTOR 512

/* 0 if a device is present and set up, -1 if not. Idempotent-safe to
 * call once and cache; platform_have_blk does exactly that.
 */
int	virtio_blk_init(void);
int	virtio_blk_present(void);

/* device size in VIRTIO_BLK_SECTOR units, 0 if absent */
uint64_t virtio_blk_capacity(void);

/* begin one transfer. `write` selects the direction; `lba` is in
 * sectors; `len` is bytes and must be a multiple of VIRTIO_BLK_SECTOR
 * and at most VIRTIO_BLK_MAXIO. For a write, src holds len bytes and is
 * copied into the slot before returning -- so the caller's buffer need
 * not outlive the call. For a read, src is ignored.
 *
 * Returns a slot, or -1 when the window is full or the request is
 * malformed. A full window is not an error: the caller yields and
 * retries, exactly as virtio_9p_start's contract has it.
 */
int	virtio_blk_start(int write, uint64_t lba, const void *src,
	    uint32_t len);

/* -1 while the device has not answered, otherwise the device's status
 * byte (0 = VIRTIO_BLK_S_OK, 1 = IOERR, 2 = UNSUPP). On 0 for a read,
 * *data points at the slot's buffer and *len is the byte count; the
 * pointer stays valid only until the next call that reuses the slot.
 *
 * The slot is released on any non-negative return, error included.
 */
int	virtio_blk_poll(int slot, const void **data, uint32_t *len);

#endif
