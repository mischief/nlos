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

/* one 9P2000 request/reply round trip: req[0,reqlen) is a complete
 * T-message (size prefix included, see lib/ninep.lua's frame()),
 * rep[0,repcap) receives the R-message. returns the reply length, or
 * -1. this is pure transport -- message framing/decoding is Lua's job
 * (los.platform.p9.rpc wraps this 1:1; see AGENTS.md "C is mechanism,
 * Lua is policy").
 */
int	virtio_9p_rpc(const void *req, size_t reqlen, void *rep, size_t repcap);

#endif
