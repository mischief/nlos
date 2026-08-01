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

/* one 9P2000 round trip, split so the caller can do something else
 * while the device works.
 *
 * It has to be split. Scheduling here is cooperative and single
 * threaded, so busy-waiting for a reply stops the whole machine, not
 * just the proc that asked -- and a mounted filesystem does this on
 * every walk, read and clunk. The Lua binding yields between polls
 * instead, which is the same shape the efi platform's net driver uses
 * (net_dial_start / net_dial_poll).
 *
 * Both buffers are owned by the transport rather than the caller: the
 * device reads the request and writes the reply on its own schedule,
 * so neither may live on a Lua stack that moves across a yield.
 *
 * start: req[0,reqlen) is a complete T-message, size prefix included
 * (see lib/ninep.lua's frame()). 0 on success, -1 if a request is
 * already in flight or the message does not fit.
 *
 * poll: -1 while the device has not answered. Otherwise the R-message
 * length, with *rep pointed at it -- valid only until the next start.
 *
 * This is pure transport; framing and decoding are Lua's job (see
 * AGENTS.md, "C is mechanism, Lua is policy").
 */
int	virtio_9p_start(const void *req, size_t reqlen);
int	virtio_9p_poll(const void **rep);

#endif
