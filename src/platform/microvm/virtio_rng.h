#ifndef MICROVM_VIRTIO_RNG_H
#define MICROVM_VIRTIO_RNG_H

#include <stddef.h>

/* probes for a virtio-rng device (see virtio_find in virtio.c) and
 * negotiates it. 0 on success, -1 if none present -- soft-fail, like
 * every other optional device on this platform.
 */
int	virtio_rng_init(void);

/* blocking: submits one device-writable descriptor over buf[0,n) and
 * waits for the device to fill it. returns bytes written, or -1 if
 * virtio_rng_init() never succeeded.
 */
int	virtio_rng_read(void *buf, size_t n);

#endif
