#ifndef NET_H
#define NET_H

/* no network on microvm: there is no virtio-net driver. Every probe
 * reports absent, and kernel.c already treats that as "no net task"
 * and moves on, which is why this is a header of stubs rather than a
 * missing file.
 *
 * The efi platform gets tcp and udp from the firmware's own EFI_TCP4
 * and EFI_UDP4. There is no such donor here, so whatever lands has to
 * be ours: virtio-net plus arp/icmp/udp, and eventually tcp, written
 * in Lua where policy belongs. Importing lwip is not on the table --
 * it would be the first third-party dependency in the tree.
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

void	*udp_open(unsigned short port, int raw);
void	udp_close(void *conn);
void	udp_cancel(void *conn);

void	*udp_send_start(void *conn, unsigned int destip_be,
	    unsigned short destport, const char *data, unsigned long n);
int	udp_send_poll(void *token);

void	*udp_recv_start(void *conn, unsigned long maxlen);
int	udp_recv_poll(void *token, void **data, unsigned long *len,
	    unsigned int *srcip_be, unsigned short *srcport);

#endif
