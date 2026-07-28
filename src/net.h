#ifndef NET_H
#define NET_H

/* raw EFI TCP4 primitives. every long-running op is two-phase
 * (start/poll) so nothing here blocks the reactor; see net.c.
 */

int	net_init(void);

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

#endif
