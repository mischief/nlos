#ifndef MICROVM_VIRTIO_9P_H
#define MICROVM_VIRTIO_9P_H

#include <stddef.h>

/* probes for a virtio-9p device (VIRTIO_ID_9P=9 -- qemu's own
 * extension, not in the official virtio spec, see hw/9pfs) and
 * negotiates it. 0 on success, -1 if none present.
 */
int	virtio_9p_init(void);

/* the mount tag from the device's config space (VIRTIO_MMIO_CONFIG,
 * u16 length + bytes), null-terminated into buf. only valid after a
 * successful virtio_9p_init(). returns the tag length, or -1 if it
 * doesn't fit in bufcap.
 */
int	virtio_9p_tag(char *buf, size_t bufcap);

/* 9P2000 round trips, split so the caller can do something else while
 * the device works, and several at once so that waiting for one does
 * not stop the rest.
 *
 * The split is not optional. Scheduling here is cooperative and single
 * threaded, so busy-waiting for a reply stops the whole machine, not
 * just the proc that asked -- and a mounted filesystem does this on
 * every walk, read and clunk. The Lua binding yields between polls
 * instead, the same shape the efi platform's net driver uses
 * (net_dial_start / net_dial_poll).
 *
 * The depth is what makes a fan-out worth doing. One request in flight
 * meant N concurrent readers took N times as long as one, since each
 * waited for the last; with a window they overlap.
 *
 * A caller is given a SLOT and holds it until it reaps the reply. That
 * slot is the whole routing mechanism: the device answers into that
 * slot's own buffer, so nothing above has to match replies to requests.
 * lib/p9fs.lua derives its 9P tag from the slot number for the same
 * reason -- a slot is owned for exactly as long as its request is
 * outstanding, so slot numbers are already unique among in-flight
 * requests, which is all a tag has to be.
 *
 * Buffers belong to the transport, not the caller: the device reads the
 * request and writes the reply on its own schedule, so neither may live
 * on a Lua stack that moves across a yield.
 *
 * start: req[0,reqlen) is a complete T-message, size prefix included
 * (see lib/ninep.lua's frame()). Returns a slot, or -1 if every slot is
 * busy or the message does not fit. A full window is an ordinary
 * outcome the caller retries, not an error.
 *
 * poll: -1 while that slot's reply has not arrived. Otherwise the
 * R-message length with *rep pointed at it, valid until the slot is
 * used again -- which cannot happen before the caller starts another
 * request, since reaping is what frees the slot.
 *
 * This is pure transport; framing, tags and decoding are Lua's job (see
 * AGENTS.md, "C is mechanism, Lua is policy").
 */
#define VIRTIO_9P_SLOTS 8

int	virtio_9p_start(const void *req, size_t reqlen);
int	virtio_9p_poll(int slot, const void **rep);

#endif
