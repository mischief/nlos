#ifndef SNP_H
#define SNP_H

#include <stddef.h>

/* snp.c -- the nic, reached through the firmware's
 * EFI_SIMPLE_NETWORK_PROTOCOL and nothing above it. snp_init takes the
 * card away from the firmware (DisconnectController), because SNP has
 * one receive queue and no fan-out: a firmware stack left bound to the
 * same handle would eat frames we never see.
 *
 * What used to be above it -- EFI_TCP4 and EFI_UDP4, re-served to Lua
 * by a net.c that is gone -- is now task/eth.lua under task/ip.lua
 * under task/tcp4.lua, which is the same stack microvm runs over
 * virtio-net. One stack, both platforms.
 */
int	snp_init(void);
int	snp_present(void);
int	snp_mac(unsigned char *out, size_t n);
int	snp_send(const void *frame, size_t n);
int	snp_recv(void *buf, size_t cap);
unsigned long snp_rx_count(void);	/* card said a frame arrived */
unsigned long snp_rx_frames(void);	/* frames actually read off it */
void	*snp_wait_event(void);	/* EFI_EVENT, or 0 if the driver has none */

#endif
