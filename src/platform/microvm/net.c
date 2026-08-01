/* no network stack on microvm in this slice -- see net.h. */

#include "lua.h"
#include "lauxlib.h"
#include "net.h"

/* have_net/have_udp are always false (net_init/net_have_udp below), so
 * kernel.c never actually spawns a PRIV_TCP/PRIV_UDP proc -- but
 * proc_new's priv switch takes these functions' addresses
 * unconditionally, so the symbols still have to exist to link.
 */
static const luaL_Reg emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_tcp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int luaopen_los_platform_udp(lua_State *L);

int
luaopen_los_platform_udp(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int net_init(void) { return -1; }
int net_have_tcp(void) { return 0; }
int net_have_udp(void) { return 0; }

int
net_hwaddr(unsigned char *out, unsigned long *len)
{
	(void)out;
	(void)len;
	return -1;
}

int
net_setaddr(unsigned int ip_be, unsigned int mask_be, unsigned int gw_be)
{
	(void)ip_be;
	(void)mask_be;
	(void)gw_be;
	return -1;
}

void *net_listen(unsigned short port) { (void)port; return 0; }
void net_close(void *conn) { (void)conn; }

void *
net_dial_start(unsigned int ipv4be, unsigned short port)
{
	(void)ipv4be;
	(void)port;
	return 0;
}

int
net_dial_poll(void *token, void **out)
{
	(void)token;
	(void)out;
	return -1;
}

void *net_accept_start(void *listener) { (void)listener; return 0; }

int
net_accept_poll(void *token, void **out)
{
	(void)token;
	(void)out;
	return -1;
}

void *
net_send_start(void *conn, const char *data, unsigned long n)
{
	(void)conn;
	(void)data;
	(void)n;
	return 0;
}

int net_send_poll(void *token) { (void)token; return -1; }

void *net_recv_start(void *conn, unsigned long maxlen)
{
	(void)conn;
	(void)maxlen;
	return 0;
}

int
net_recv_poll(void *token, void **data, unsigned long *len)
{
	(void)token;
	(void)data;
	(void)len;
	return -1;
}

void *udp_open(unsigned short port, int raw) { (void)port; (void)raw; return 0; }
void udp_close(void *conn) { (void)conn; }
void udp_cancel(void *conn) { (void)conn; }

void *
udp_send_start(void *conn, unsigned int destip_be, unsigned short destport,
    const char *data, unsigned long n)
{
	(void)conn;
	(void)destip_be;
	(void)destport;
	(void)data;
	(void)n;
	return 0;
}

int udp_send_poll(void *token) { (void)token; return -1; }

void *udp_recv_start(void *conn, unsigned long maxlen)
{
	(void)conn;
	(void)maxlen;
	return 0;
}

int
udp_recv_poll(void *token, void **data, unsigned long *len,
    unsigned int *srcip_be, unsigned short *srcport)
{
	(void)token;
	(void)data;
	(void)len;
	(void)srcip_be;
	(void)srcport;
	return -1;
}
