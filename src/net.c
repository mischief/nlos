/* raw EFI TCP4 primitives: locate the service, listen, accept,
 * transmit, receive, close. every long-running op is two-phase
 * (start issues the token and registers its Event with the kernel's
 * dynamic wait-set; poll checks completion) so nothing here ever
 * blocks the reactor -- unlike fs.c/console.c's synchronous EFI
 * calls, tcp4 is fundamentally async under the hood and this is the
 * seam that has to respect that.
 *
 * this is the raw layer only (mirrors fs.c's role for espfs); the
 * exclusive "net" task and its request/reply protocol are the next
 * piece up, same shape as lib/wire.lua.
 */

#include <stdlib.h>
#include <string.h>

#include "efi.h"
#include "kernel.h"
#include "net.h"

#include "lua.h"
#include "lauxlib.h"

static EFI_GUID tcp4_sb_guid = { 0x00720665, 0x67EB, 0x4a99,
	{ 0xBA, 0xF7, 0xD3, 0xC3, 0x3A, 0x1C, 0x7C, 0xC9 } };
static EFI_GUID tcp4_guid = { 0x65530BC7, 0xA359, 0x410f,
	{ 0xB0, 0x10, 0x5A, 0xAD, 0xC7, 0xEC, 0x2B, 0x62 } };

static EFI_SERVICE_BINDING_PROTOCOL *tcp4_sb;

int
net_init(void)
{
	EFI_HANDLE *handles;
	UINTN count, i;
	EFI_STATUS st;

	st = BS->LocateHandleBuffer(2 /* ByProtocol */, &tcp4_sb_guid, 0,
	    &count, &handles);
	if (st != EFI_SUCCESS || count == 0)
		return -1;

	for (i = 0; i < count; i++) {
		if (BS->HandleProtocol(handles[i], &tcp4_sb_guid,
		    (void **)&tcp4_sb) == EFI_SUCCESS)
			break;
	}
	BS->FreePool(handles);
	return tcp4_sb ? 0 : -1;
}

/* a connection: either a listener (accept only) or an accepted/
 * dialed peer (transmit+receive). one EFI_TCP4_PROTOCOL child plus
 * whichever token is currently outstanding.
 */
struct netconn {
	EFI_TCP4_PROTOCOL *tcp;
	EFI_HANDLE handle;
};

static struct netconn *
netconn_new(void)
{
	struct netconn *c = malloc(sizeof *c);

	if (!c)
		return 0;
	/* CreateChild's ChildHandle must point to NULL on input (spec:
	 * a non-NULL value means "add to this existing handle" instead
	 * of creating a new one) -- malloc doesn't zero, so this has to
	 * be explicit. worked by luck of memory content history until
	 * this was caught chasing an identical bug elsewhere.
	 */
	c->handle = 0;
	if (tcp4_sb->CreateChild(tcp4_sb, &c->handle) != EFI_SUCCESS) {
		free(c);
		return 0;
	}
	if (BS->HandleProtocol(c->handle, &tcp4_guid,
	    (void **)&c->tcp) != EFI_SUCCESS) {
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}
	return c;
}

extern void console_write(const char *s, unsigned long n);

static void
debug_status(const char *label, EFI_STATUS st)
{
	char buf[64];
	int n = 0;

	buf[n++] = 'D';
	buf[n++] = 'B';
	buf[n++] = 'G';
	buf[n++] = ' ';
	while (*label)
		buf[n++] = *label++;
	buf[n++] = ':';
	buf[n++] = ' ';
	buf[n++] = '0';
	buf[n++] = 'x';
	for (int shift = 60; shift >= 0; shift -= 4) {
		int nib = (st >> shift) & 0xf;

		buf[n++] = nib < 10 ? '0' + nib : 'a' + nib - 10;
	}
	buf[n++] = '\n';
	console_write(buf, n);
}

void *
net_listen(unsigned short port)
{
	struct netconn *c = netconn_new();
	EFI_TCP4_CONFIG_DATA cfg;
	EFI_STATUS st;

	if (!c) {
		debug_status("netconn_new", 0xdead);
		return 0;
	}
	memset(&cfg, 0, sizeof cfg);
	cfg.AccessPoint.UseDefaultAddress = 1;
	cfg.AccessPoint.StationPort = port;
	cfg.AccessPoint.ActiveFlag = 0;
	st = c->tcp->Configure(c->tcp, &cfg);
	if (st != EFI_SUCCESS) {
		/* EFI_NO_MAPPING is the expected, normal status until DHCP
		 * completes -- Configure() self-triggers it but doesn't
		 * block, so callers retry (see the spin loops in init.lua/
		 * srvnet.lua). logging that every retry is just boot noise;
		 * anything else here is a real, unexpected failure.
		 */
		if (st != EFI_NO_MAPPING)
			debug_status("Configure", st);
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}
	return c;
}

/* dial is two-phase like everything else async here: Configure()
 * with ActiveFlag=1 only *prepares* an active connection per the
 * uefi spec -- it does NOT perform the handshake. Connect() is the
 * separate async step that actually does (SYN, wait for the 3-way
 * handshake to finish). this was originally written as a single
 * synchronous Configure()-only call that returned an unconnected
 * netconn -- never caught because dial had no real caller until an
 * http client exercised it for the first time; Transmit on the
 * not-yet-connected instance just failed silently.
 */
struct dialtoken {
	EFI_TCP4_CONNECTION_TOKEN tok;
	struct netconn *conn;
};

void *
net_dial_start(unsigned int ipv4be, unsigned short port)
{
	struct netconn *c = netconn_new();
	EFI_TCP4_CONFIG_DATA cfg;

	if (!c)
		return 0;
	memset(&cfg, 0, sizeof cfg);
	cfg.AccessPoint.UseDefaultAddress = 1;
	memcpy(cfg.AccessPoint.RemoteAddress, &ipv4be, 4);
	cfg.AccessPoint.RemotePort = port;
	cfg.AccessPoint.ActiveFlag = 1;
	if (c->tcp->Configure(c->tcp, &cfg) != EFI_SUCCESS) {
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}

	struct dialtoken *dt = malloc(sizeof *dt);

	if (!dt) {
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}
	memset(&dt->tok, 0, sizeof dt->tok);
	dt->conn = c;
	dt->tok.CompletionToken.Event = kernel_new_net_event();
	if (!dt->tok.CompletionToken.Event) {
		free(dt);
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}

	EFI_STATUS cst = c->tcp->Connect(c->tcp, &dt->tok);

	if (cst != EFI_SUCCESS) {
		debug_status("Connect", cst);
		BS->CloseEvent(dt->tok.CompletionToken.Event);
		free(dt);
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}
	return dt;
}

/* returns: 1 = done (out set to the now-connected struct netconn*,
 * the same one created in dial_start, or 0 on a failed handshake),
 * 0 = still pending -- same CheckEvent-not-Status shape as every
 * other poll function here.
 */
int
net_dial_poll(void *token, void **out)
{
	struct dialtoken *dt = token;

	if (BS->CheckEvent(dt->tok.CompletionToken.Event) != EFI_SUCCESS)
		return 0;

	BS->CloseEvent(dt->tok.CompletionToken.Event);

	if (dt->tok.CompletionToken.Status != EFI_SUCCESS) {
		debug_status("connect completion",
		    dt->tok.CompletionToken.Status);
		tcp4_sb->DestroyChild(tcp4_sb, dt->conn->handle);
		free(dt->conn);
		free(dt);
		*out = 0;
		return 1;
	}
	*out = dt->conn;
	free(dt);
	return 1;
}

/* ---- accept (listener only) ---- */

void *
net_accept_start(void *conn)
{
	struct netconn *c = conn;
	EFI_TCP4_LISTEN_TOKEN *tok = malloc(sizeof *tok);

	if (!tok)
		return 0;
	memset(tok, 0, sizeof *tok);
	tok->CompletionToken.Event = kernel_new_net_event();
	if (!tok->CompletionToken.Event) {
		free(tok);
		return 0;
	}
	EFI_STATUS ast = c->tcp->Accept(c->tcp, tok);

	if (ast != EFI_SUCCESS) {
		debug_status("Accept", ast);
		BS->CloseEvent(tok->CompletionToken.Event);
		free(tok);
		return 0;
	}
	return tok;
}

/* returns: 1 = done (out set to a new struct netconn*, or 0 on peer
 * error), 0 = still pending. status is only meaningful once the
 * event has actually fired -- CheckEvent, not a Status sentinel, is
 * what tells us that (the token is zero-initialized, and EFI_SUCCESS
 * is itself 0, so trusting Status before the event fires would read
 * a freshly-started op as already complete).
 */
int
net_accept_poll(void *token, void **out)
{
	EFI_TCP4_LISTEN_TOKEN *tok = token;

	if (BS->CheckEvent(tok->CompletionToken.Event) != EFI_SUCCESS)
		return 0;

	BS->CloseEvent(tok->CompletionToken.Event);

	if (tok->CompletionToken.Status != EFI_SUCCESS) {
		debug_status("accept completion", tok->CompletionToken.Status);
		free(tok);
		*out = 0;
		return 1;
	}

	struct netconn *nc = malloc(sizeof *nc);

	if (nc) {
		nc->handle = tok->NewChildHandle;
		BS->HandleProtocol(nc->handle, &tcp4_guid,
		    (void **)&nc->tcp);
	}
	free(tok);
	*out = nc;
	return 1;
}

/* ---- transmit / receive (accepted/dialed connections) ---- */

void *
net_send_start(void *conn, const char *data, unsigned long n)
{
	struct netconn *c = conn;
	EFI_TCP4_IO_TOKEN *tok = malloc(sizeof *tok);
	EFI_TCP4_TRANSMIT_DATA *td = malloc(sizeof *td);
	/* Transmit() is async -- the real hardware send happens later,
	 * whenever send_poll's CheckEvent confirms completion. `data`
	 * here is a lua_State's GC-managed string pointer (from
	 * luaL_checklstring); pointing FragmentBuffer straight at it
	 * and returning is a real bug -- nothing roots that string for
	 * the caller's *next* GC cycle, which can run before the actual
	 * transmit does, freeing/reusing the memory out from under it.
	 * own a copy so its lifetime is ours, not the GC's.
	 */
	void *copy = malloc(n);

	if (!tok || !td || (n && !copy)) {
		free(tok);
		free(td);
		free(copy);
		return 0;
	}
	memcpy(copy, data, n);
	memset(tok, 0, sizeof *tok);
	td->Push = 1;
	td->Urgent = 0;
	td->DataLength = n;
	td->FragmentCount = 1;
	td->FragmentTable[0].FragmentLength = n;
	td->FragmentTable[0].FragmentBuffer = (void *)data;
	tok->Packet.TxData = td;

	tok->CompletionToken.Event = kernel_new_net_event();
	if (!tok->CompletionToken.Event) {
		free(tok);
		free(td);
		return 0;
	}
	if (c->tcp->Transmit(c->tcp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->CompletionToken.Event);
		free(tok);
		free(td);
		return 0;
	}
	return tok;
}

int
net_send_poll(void *token)
{
	EFI_TCP4_IO_TOKEN *tok = token;

	if (BS->CheckEvent(tok->CompletionToken.Event) != EFI_SUCCESS)
		return 0;
	BS->CloseEvent(tok->CompletionToken.Event);
	free(tok->Packet.TxData->FragmentTable[0].FragmentBuffer);
	free(tok->Packet.TxData);
	free(tok);
	return 1;
}

void *
net_recv_start(void *conn, unsigned long maxlen)
{
	struct netconn *c = conn;
	EFI_TCP4_IO_TOKEN *tok = malloc(sizeof *tok);
	EFI_TCP4_RECEIVE_DATA *rd = malloc(sizeof *rd);
	void *buf = malloc(maxlen);

	if (!tok || !rd || !buf) {
		free(tok);
		free(rd);
		free(buf);
		return 0;
	}
	memset(tok, 0, sizeof *tok);
	rd->UrgentFlag = 0;
	rd->DataLength = maxlen;
	rd->FragmentCount = 1;
	rd->FragmentTable[0].FragmentLength = maxlen;
	rd->FragmentTable[0].FragmentBuffer = buf;
	tok->Packet.RxData = rd;

	tok->CompletionToken.Event = kernel_new_net_event();
	if (!tok->CompletionToken.Event) {
		free(tok);
		free(rd);
		free(buf);
		return 0;
	}
	if (c->tcp->Receive(c->tcp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->CompletionToken.Event);
		free(tok);
		free(rd);
		free(buf);
		return 0;
	}
	return tok;
}

/* returns: 1 = done (data/len set on success, data=0/len=0 on a
 * connection error/close -- caller must free(data) when non-null),
 * 0 = pending
 */
int
net_recv_poll(void *token, void **data, unsigned long *len)
{
	EFI_TCP4_IO_TOKEN *tok = token;

	if (BS->CheckEvent(tok->CompletionToken.Event) != EFI_SUCCESS)
		return 0;
	BS->CloseEvent(tok->CompletionToken.Event);

	if (tok->CompletionToken.Status != EFI_SUCCESS) {
		free(tok->Packet.RxData->FragmentTable[0].FragmentBuffer);
		free(tok->Packet.RxData);
		free(tok);
		*data = 0;
		*len = 0;
		return 1;
	}
	*data = tok->Packet.RxData->FragmentTable[0].FragmentBuffer;
	*len = tok->Packet.RxData->DataLength;
	free(tok->Packet.RxData);
	free(tok);
	return 1;
}

void
net_close(void *conn)
{
	struct netconn *c = conn;

	/* abort any token still outstanding (an accept/send/recv the
	 * caller never polled to completion) before tearing down --
	 * Cancel(NULL) aborts everything on this instance and signals
	 * their events, so whichever poll function still owns that
	 * token sees a normal (error) completion on its next check and
	 * frees it through the existing path. no separate bookkeeping
	 * needed in net.lua for this.
	 */
	c->tcp->Cancel(c->tcp, 0);
	c->tcp->Configure(c->tcp, 0);
	tcp4_sb->DestroyChild(tcp4_sb, c->handle);
	free(c);
}

/* ---- los.platform.net: lua bindings, registered ONLY for the net
 * task (see kernel.c's proc_new). raw C handles (connections, tokens)
 * cross into lua as follows.
 *
 * connection handles cross as full userdata -- a small "box" holding
 * one pointer, with a __gc metamethod -- not lightuserdata.
 * lightuserdata is invisible to the gc: if lua code ever drops its
 * last reference without an explicit close(), or if this whole task's
 * proc dies (crash or otherwise), nothing would ever release the
 * underlying efi child handle. a full userdata's __gc runs in both
 * cases -- lua_close() during proc teardown runs every live __gc, so
 * a crashed net task still cleans up whatever it had open. explicit
 * close() nulls the box so a later gc pass is a no-op instead of a
 * double-close.
 *
 * tokens (in-flight accept/send/recv) stay plain lightuserdata: their
 * lifetime is already tightly bounded by lib/net.lua's own
 * pending-table bookkeeping (checkpending() always drives them to
 * completion and frees exactly once), so there's no gc benefit to
 * boxing them too.
 */

struct connbox {
	void *conn;	/* NULL once explicitly closed */
};

static int
l_netconn_gc(lua_State *L)
{
	struct connbox *box = luaL_checkudata(L, 1, "netconn");

	if (box->conn) {
		net_close(box->conn);
		box->conn = 0;
	}
	return 0;
}

static void
push_netconn(lua_State *L, void *c)
{
	struct connbox *box = lua_newuserdata(L, sizeof *box);

	box->conn = c;
	luaL_setmetatable(L, "netconn");
}

static void *
check_netconn(lua_State *L, int idx)
{
	struct connbox *box = luaL_checkudata(L, idx, "netconn");

	luaL_argcheck(L, box->conn != NULL, idx, "connection already closed");
	return box->conn;
}

static int
l_net_listen(lua_State *L)
{
	void *c = net_listen((unsigned short)luaL_checkinteger(L, 1));

	if (!c)
		return 0;
	push_netconn(L, c);
	return 1;
}

static int
l_net_dial_start(lua_State *L)
{
	unsigned char octets[4];

	for (int i = 0; i < 4; i++)
		octets[i] = (unsigned char)luaL_checkinteger(L, i + 1);

	unsigned int ip;

	memcpy(&ip, octets, 4);

	void *tok = net_dial_start(ip, (unsigned short)luaL_checkinteger(L, 5));

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_net_dial_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);

	void *out = 0;
	int done = net_dial_poll(lua_touserdata(L, 1), &out);

	if (!done) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	if (out) {
		push_netconn(L, out);
		return 2;
	}
	return 1;	/* done, but handshake failed: (true, nil) */
}

static int
l_net_close(lua_State *L)
{
	return l_netconn_gc(L);
}

static int
l_net_accept_start(lua_State *L)
{
	void *tok = net_accept_start(check_netconn(L, 1));

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_net_accept_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);

	void *out = 0;
	int done = net_accept_poll(lua_touserdata(L, 1), &out);

	if (!done) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	if (out) {
		push_netconn(L, out);
		return 2;
	}
	return 1;	/* done, but peer error: (true, nil) */
}

static int
l_net_send_start(lua_State *L)
{
	void *conn = check_netconn(L, 1);
	size_t n;
	const char *s = luaL_checklstring(L, 2, &n);
	void *tok = net_send_start(conn, s, n);

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_net_send_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	lua_pushboolean(L, net_send_poll(lua_touserdata(L, 1)));
	return 1;
}

static int
l_net_recv_start(lua_State *L)
{
	void *conn = check_netconn(L, 1);
	lua_Integer maxlen = luaL_optinteger(L, 2, 4096);
	void *tok = net_recv_start(conn, (unsigned long)maxlen);

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_net_recv_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);

	void *data = 0;
	unsigned long len = 0;
	int done = net_recv_poll(lua_touserdata(L, 1), &data, &len);

	if (!done) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	if (data) {
		lua_pushlstring(L, data, len);
		free(data);
		return 2;
	}
	return 1;	/* done, but connection closed/errored: (true, nil) */
}

static const luaL_Reg netlib[] = {
	{ "listen", l_net_listen },
	{ "dial_start", l_net_dial_start },
	{ "dial_poll", l_net_dial_poll },
	{ "close", l_net_close },
	{ "accept_start", l_net_accept_start },
	{ "accept_poll", l_net_accept_poll },
	{ "send_start", l_net_send_start },
	{ "send_poll", l_net_send_poll },
	{ "recv_start", l_net_recv_start },
	{ "recv_poll", l_net_recv_poll },
	{ NULL, NULL }
};

int luaopen_los_platform_net(lua_State *L);

int
luaopen_los_platform_net(lua_State *L)
{
	luaL_newmetatable(L, "netconn");
	lua_pushcfunction(L, l_netconn_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newlib(L, netlib);
	return 1;
}
