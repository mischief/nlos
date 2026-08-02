#ifndef NET_H
#define NET_H

#include <stddef.h>	/* size_t, for the snp entry points below */

/* raw EFI TCP4 primitives. every long-running op is two-phase
 * (start/poll) so nothing here blocks the reactor; see net.c.
 */

int	net_init(void);
int	net_have_tcp(void);
int	net_hwaddr(unsigned char *out, unsigned long *len);
int	net_setaddr(unsigned int ip_be, unsigned int mask_be, unsigned int gw_be);
int	net_have_udp(void);

void	*net_listen(unsigned short port);
void	net_close(void *conn);

void	*net_dial_start(unsigned int ipv4be, unsigned short port);
int	net_dial_poll(void *token, void **out);

void	*net_accept_start(void *listener);
int	net_accept_poll(void *token, void **out);

void	*net_send_start(void *conn, const char *data, unsigned long n);
int	net_send_poll(void *token);

void	*net_recv_start(void *conn, unsigned long maxlen);
int	net_recv_poll(void *token, void **data, unsigned long *len);

/* raw EFI UDP4 primitives: connectionless, one child bound to a local
 * port, used for both send and receive. every send names its
 * destination explicitly; every receive reports where the datagram
 * actually came from. soft-fails independently of tcp4 (net_init()
 * succeeds if tcp4 alone is present -- these just return 0/fail if
 * no udp4 service binding was ever found).
 */
void	*udp_open(unsigned short port, int raw);
void	udp_close(void *conn);
void	udp_cancel(void *conn);

void	*udp_send_start(void *conn, unsigned int destip_be,
	    unsigned short destport, const char *data, unsigned long n);
int	udp_send_poll(void *token);

void	*udp_recv_start(void *conn, unsigned long maxlen);
int	udp_recv_poll(void *token, void **data, unsigned long *len,
	    unsigned int *srcip_be, unsigned short *srcport);

/* snp.c -- the nic underneath all of the above, reached directly. The
 * two are alternatives, not layers: snp_init takes the card away from
 * the firmware (DisconnectController), which is what stops the drivers
 * net.c uses from working on that handle.
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
