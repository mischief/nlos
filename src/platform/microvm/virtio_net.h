#ifndef MICROVM_VIRTIO_NET_H
#define MICROVM_VIRTIO_NET_H

#include <stddef.h>

/* virtio-net over virtio-mmio: raw ethernet frames in and out, and
 * nothing above that.
 *
 * Deliberately only frames. There is no firmware stack to inherit here
 * the way the efi platform inherits EFI_TCP4, so whatever arp, ip, icmp
 * and udp this machine gets will be written -- and they belong in Lua,
 * where policy belongs, not behind another C interface. This file moves
 * bytes between a Lua string and a virtqueue and stops there.
 *
 * 0 on success, -1 if no device is present.
 */
int	virtio_net_init(void);

/* the device's mac, from config space. -1 if the device did not offer
 * VIRTIO_NET_F_MAC, in which case the caller has to invent one.
 */
int	virtio_net_mac(unsigned char out[6]);

/* transmit frame[0,n). 0 on success, -1 if no transmit buffer is free
 * or the frame is too long. Completions are reclaimed here rather than
 * waited for, so a caller that transmits steadily never blocks.
 */
int	virtio_net_send(const void *frame, size_t n);

/* the next received frame into buf[0,cap), or 0 when none has arrived.
 * -1 if the frame did not fit. Non-blocking by construction: frames
 * turn up unasked, so there is nothing to wait for that a caller could
 * not do better itself.
 */
int	virtio_net_recv(void *buf, size_t cap);

#endif
