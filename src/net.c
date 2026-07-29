/* raw EFI TCP4/UDP4 primitives: locate the services, listen/dial/
 * accept/open, transmit, receive, close. every long-running op is
 * two-phase (start issues the token and registers its Event with the
 * kernel's dynamic wait-set; poll checks completion) so nothing here
 * ever blocks the reactor -- unlike fs.c/console.c's synchronous EFI
 * calls, tcp4/udp4 are fundamentally async under the hood and this is
 * the seam that has to respect that.
 *
 * this is the raw layer only (mirrors fs.c's role for espfs); the
 * exclusive tcp and udp tasks and their request/reply protocols are
 * the next piece up, same shape as lib/wire.lua.
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
static EFI_GUID udp4_sb_guid = { 0x83f01464, 0x99bd, 0x45e5,
	{ 0xb3, 0x83, 0xaf, 0x63, 0x05, 0xd8, 0xe9, 0xe6 } };
static EFI_GUID udp4_guid = { 0x3ad9df29, 0x4501, 0x478d,
	{ 0xb1, 0xf8, 0x7f, 0x7f, 0xe7, 0x0e, 0x50, 0xf3 } };

static EFI_SERVICE_BINDING_PROTOCOL *tcp4_sb;
static EFI_SERVICE_BINDING_PROTOCOL *udp4_sb;

static EFI_SERVICE_BINDING_PROTOCOL *
locate_sb(EFI_GUID *guid)
{
	EFI_HANDLE *handles;
	UINTN count, i;
	EFI_SERVICE_BINDING_PROTOCOL *sb = 0;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, guid, 0,
	    &count, &handles) != EFI_SUCCESS || count == 0)
		return 0;
	for (i = 0; i < count; i++) {
		if (BS->HandleProtocol(handles[i], guid,
		    (void **)&sb) == EFI_SUCCESS)
			break;
	}
	BS->FreePool(handles);
	return sb;
}

int
net_init(void)
{
	tcp4_sb = locate_sb(&tcp4_sb_guid);
	/* udp4 is soft-fail, independent of tcp4: a firmware/NIC combo
	 * that only wires up one of the two shouldn't take the other
	 * down with it. kernel.c's net_have_udp() checks this after
	 * net_init() returns to decide whether to spawn the udp task.
	 */
	udp4_sb = locate_sb(&udp4_sb_guid);
	return tcp4_sb ? 0 : -1;
}

int
net_have_tcp(void)
{
	return tcp4_sb != 0;
}

int
net_have_udp(void)
{
	return udp4_sb != 0;
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

/* ---- tcp4 ---- */

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
	 * this was caught chasing an identical bug in udp_open.
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
		 * completes, so callers retry (see the spin loops in
		 * init.lua/srvnet.lua). logging that every retry is just boot
		 * noise; anything else here is a real, unexpected failure.
		 *
		 * DO NOT try to make this faster by starting earlier or
		 * polling harder. Measured on qemu usermode net, where the
		 * DHCP server answers a DISCOVER instantly:
		 *
		 *   poll every 250ms   14 attempts, mapped at t=4746ms
		 *   poll every 1500ms   4 attempts, mapped at t=5490ms
		 *   sleep 3s, then poll 4 attempts, mapped at t=4797ms
		 *
		 * the ABSOLUTE completion time is ~4.8s from boot however
		 * often, and however early, anyone asks. Configure() does not
		 * self-trigger DHCP -- the firmware's Ip4Config2 runs it on
		 * its own schedule once the NIC is up, and this call only
		 * *polls* for the result. so an early kick buys nothing (tried:
		 * a persistent prober child Configure()d at tcp-task startup
		 * moved the number by 128ms, i.e. noise), and neither does
		 * keeping the child instead of recreating it.
		 *
		 * what WOULD remove the wait is not asking for DHCP at all:
		 * UseDefaultAddress = 0 with an explicit StationAddress and
		 * SubnetMask. worth it for a fixed deployment, which is the
		 * only place the 3.3s is actually felt.
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
 * http client exercised it for the first time this session; Transmit
 * on the not-yet-connected instance just failed silently.
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
		debug_status("connect completion", dt->tok.CompletionToken.Status);
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
	td->FragmentTable[0].FragmentBuffer = copy;
	tok->Packet.TxData = td;

	tok->CompletionToken.Event = kernel_new_net_event();
	if (!tok->CompletionToken.Event) {
		free(tok);
		free(td);
		free(copy);
		return 0;
	}
	if (c->tcp->Transmit(c->tcp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->CompletionToken.Event);
		free(tok);
		free(td);
		free(copy);
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
	 * needed in net.lua/udp.lua for this.
	 */
	c->tcp->Cancel(c->tcp, 0);
	c->tcp->Configure(c->tcp, 0);
	tcp4_sb->DestroyChild(tcp4_sb, c->handle);
	free(c);
}

/* ---- udp4: connectionless, one child bound to a local port, used
 * for both send and receive. no listen/accept/connect state machine
 * -- every send names its destination explicitly (UdpSessionData),
 * every receive reports where the datagram actually came from.
 */

struct udpconn {
	EFI_UDP4_PROTOCOL *udp;
	EFI_HANDLE handle;
};

void *
udp_open(unsigned short port)
{
	if (!udp4_sb)
		return 0;

	struct udpconn *c = malloc(sizeof *c);

	if (!c)
		return 0;
	c->handle = 0;	/* CreateChild requires NULL on input, see net_listen */

	EFI_STATUS cst = udp4_sb->CreateChild(udp4_sb, &c->handle);

	if (cst != EFI_SUCCESS) {
		debug_status("udp CreateChild", cst);
		free(c);
		return 0;
	}

	EFI_STATUS hst = BS->HandleProtocol(c->handle, &udp4_guid,
	    (void **)&c->udp);

	if (hst != EFI_SUCCESS) {
		debug_status("udp HandleProtocol", hst);
		udp4_sb->DestroyChild(udp4_sb, c->handle);
		free(c);
		return 0;
	}

	EFI_UDP4_CONFIG_DATA cfg;

	memset(&cfg, 0, sizeof cfg);
	cfg.UseDefaultAddress = 1;
	cfg.StationPort = port;	/* 0: firmware picks an ephemeral port */
	/* ReceiveTimeout only discards already-arrived-but-unclaimed
	 * datagrams sitting in the driver's own internal queue (verified
	 * by reading Udp4Impl.c/Udp4Main.c) -- it does NOT time out a
	 * pending Receive() token still waiting for data that never
	 * shows up, so it's not useful for "give up after N seconds"
	 * retry logic. real udp clients that need that (dns, say) do
	 * their own wall-clock poll loop and call udp_cancel() below.
	 */
	cfg.ReceiveTimeout = 0;
	cfg.TransmitTimeout = 0;
	/* left at 0 (memset above) this is a literal TTL=0 -- confirmed
	 * via packet capture: outgoing replies died at the first hop
	 * with an ICMP "time exceeded in-transit" from qemu's own
	 * usermode gateway. udp4Dxe takes it literally, unlike whatever
	 * default path tcp4 rides through; 64 is the common OS default.
	 */
	cfg.TimeToLive = 64;
	/* RemoteAddress/RemotePort left zero: not bound to one peer,
	 * every Transmit names its destination via UdpSessionData
	 * instead (see udp_send_start).
	 */
	EFI_STATUS st = c->udp->Configure(c->udp, &cfg);

	if (st != EFI_SUCCESS) {
		if (st != EFI_NO_MAPPING)
			debug_status("udp Configure", st);
		udp4_sb->DestroyChild(udp4_sb, c->handle);
		free(c);
		return 0;
	}
	return c;
}

void
udp_close(void *conn)
{
	struct udpconn *c = conn;

	c->udp->Cancel(c->udp, 0);	/* see net_close's Cancel comment */
	c->udp->Configure(c->udp, 0);
	udp4_sb->DestroyChild(udp4_sb, c->handle);
	free(c);
}

/* abort any outstanding token on this connection WITHOUT closing it
 * -- for a caller doing its own wall-clock retry/timeout (dns, say):
 * Cancel(NULL) aborts everything in flight and signals their events,
 * so whichever poll function owns that token sees a normal (error)
 * completion on its next check, same mechanism udp_close relies on,
 * just without tearing down the connection itself.
 */
void
udp_cancel(void *conn)
{
	struct udpconn *c = conn;

	c->udp->Cancel(c->udp, 0);
}

void *
udp_send_start(void *conn, unsigned int destip_be, unsigned short destport,
    const char *data, unsigned long n)
{
	struct udpconn *c = conn;
	EFI_UDP4_COMPLETION_TOKEN *tok = malloc(sizeof *tok);
	EFI_UDP4_TRANSMIT_DATA *td = malloc(sizeof *td);
	EFI_UDP4_SESSION_DATA *sess = malloc(sizeof *sess);
	/* own a copy instead of pointing at the caller's buffer directly
	 * -- same reasoning as net_send_start's copy: Transmit() is
	 * async, and `data` here is typically a lua_State's GC-managed
	 * string pointer with no lifetime guarantee past this call.
	 * confirmed via packet capture: without this, the real transmit
	 * read garbage (0xAF, a stale/reused-memory pattern) instead of
	 * the actual payload.
	 */
	void *copy = malloc(n);

	if (!tok || !td || !sess || (n && !copy)) {
		free(tok);
		free(td);
		free(sess);
		free(copy);
		return 0;
	}
	memcpy(copy, data, n);
	memset(tok, 0, sizeof *tok);
	memset(sess, 0, sizeof *sess);
	memcpy(sess->DestinationAddress, &destip_be, 4);
	sess->DestinationPort = destport;
	/* SourceAddress/SourcePort left zero: use the station address/
	 * port this instance was Configure()'d with.
	 */
	td->UdpSessionData = sess;
	td->GatewayAddress = 0;
	td->DataLength = n;
	td->FragmentCount = 1;
	td->FragmentTable[0].FragmentLength = n;
	td->FragmentTable[0].FragmentBuffer = copy;
	tok->Packet.TxData = td;

	tok->Event = kernel_new_net_event();
	if (!tok->Event) {
		free(tok);
		free(td);
		free(sess);
		free(copy);
		return 0;
	}
	if (c->udp->Transmit(c->udp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->Event);
		free(tok);
		free(td);
		free(sess);
		free(copy);
		return 0;
	}
	return tok;
}

int
udp_send_poll(void *token)
{
	EFI_UDP4_COMPLETION_TOKEN *tok = token;

	if (BS->CheckEvent(tok->Event) != EFI_SUCCESS)
		return 0;
	BS->CloseEvent(tok->Event);
	free(tok->Packet.TxData->UdpSessionData);
	free(tok->Packet.TxData->FragmentTable[0].FragmentBuffer);
	free(tok->Packet.TxData);
	free(tok);
	return 1;
}

/* unlike tcp4's Receive() (caller supplies FragmentBuffer, driver
 * writes into it), udp4's Receive() has the driver allocate and own
 * RxData itself -- confirmed by reading the real driver source
 * (NetworkPkg/Udp4Dxe/Udp4Impl.c's Udp4WrapRxData: it AllocatePool's
 * its own EFI_UDP4_RECEIVE_DATA and overwrites Token->Packet.RxData
 * with that pointer). the extra TimeStamp/RecycleSignal fields udp4's
 * RECEIVE_DATA has that tcp4's doesn't are the tell: RecycleSignal is
 * how the caller hands the driver's buffer back, not something we
 * free() ourselves -- doing that once corrupted this module's own
 * heap (freed a pointer malloc() never allocated). maxlen is unused:
 * udp4 doesn't take a caller-supplied receive buffer at all.
 */
void *
udp_recv_start(void *conn, unsigned long maxlen)
{
	struct udpconn *c = conn;
	EFI_UDP4_COMPLETION_TOKEN *tok = malloc(sizeof *tok);

	(void)maxlen;
	if (!tok)
		return 0;
	memset(tok, 0, sizeof *tok);

	tok->Event = kernel_new_net_event();
	if (!tok->Event) {
		free(tok);
		return 0;
	}
	if (c->udp->Receive(c->udp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->Event);
		free(tok);
		return 0;
	}
	return tok;
}

/* returns: 1 = done (data/len/srcip/srcport set on success, data=0 on
 * error), 0 = pending. same zero-init-vs-EFI_SUCCESS caveat as tcp4's
 * poll functions -- CheckEvent, not Status, is the real signal.
 */
int
udp_recv_poll(void *token, void **data, unsigned long *len,
    unsigned int *srcip_be, unsigned short *srcport)
{
	EFI_UDP4_COMPLETION_TOKEN *tok = token;

	if (BS->CheckEvent(tok->Event) != EFI_SUCCESS)
		return 0;
	BS->CloseEvent(tok->Event);

	if (tok->Status != EFI_SUCCESS) {
		free(tok);
		*data = 0;
		*len = 0;
		return 1;
	}

	EFI_UDP4_RECEIVE_DATA *rd = tok->Packet.RxData;
	unsigned long n = rd->DataLength;
	/* malloc(0) is allowed to return NULL, and a zero-length udp
	 * datagram is a perfectly ordinary thing to receive -- always
	 * ask for at least one byte so "NULL" unambiguously means the
	 * allocation failed, never "the datagram was empty".
	 */
	void *buf = malloc(n ? n : 1);	/* our own copy, ours to free() normally */

	if (buf) {
		unsigned long off = 0;

		for (UINT32 i = 0; i < rd->FragmentCount && off < n; i++) {
			unsigned long flen = rd->FragmentTable[i].FragmentLength;

			if (off + flen > n)
				flen = n - off;
			memcpy((char *)buf + off,
			    rd->FragmentTable[i].FragmentBuffer, flen);
			off += flen;
		}
	}
	memcpy(srcip_be, rd->UdpSession.SourceAddress, 4);
	*srcport = rd->UdpSession.SourcePort;

	/* return the driver's own buffer to it -- the actual contract,
	 * not free(): see the comment above udp_recv_start.
	 */
	BS->SignalEvent(rd->RecycleSignal);

	free(tok);
	*data = buf;
	*len = buf ? n : 0;
	return 1;	/* buf == 0 here means OOM, and only OOM */
}

/* ---- lua bindings ----
 *
 * connection handles (netconn/udpconn) cross into lua as full
 * userdata -- a small "box" holding one pointer, with a __gc
 * metamethod -- not lightuserdata. lightuserdata is invisible to the
 * gc: if lua code ever drops its last reference without an explicit
 * close(), or if this whole task's proc dies (crash or otherwise),
 * nothing would ever release the underlying efi child handle. a full
 * userdata's __gc runs in both cases -- lua_close() during proc
 * teardown runs every live __gc, so a crashed tcp/udp task still
 * cleans up whatever it had open. explicit close() nulls the box so
 * a later gc pass is a no-op instead of a double-close.
 *
 * tokens (in-flight accept/send/recv) stay plain lightuserdata: their
 * lifetime is already tightly bounded by lib/tcp.lua's/lib/udp.lua's
 * own pending-table bookkeeping (checkpending() always drives them to
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

static int
l_udpconn_gc(lua_State *L)
{
	struct connbox *box = luaL_checkudata(L, 1, "udpconn");

	if (box->conn) {
		udp_close(box->conn);
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

static void
push_udpconn(lua_State *L, void *c)
{
	struct connbox *box = lua_newuserdata(L, sizeof *box);

	box->conn = c;
	luaL_setmetatable(L, "udpconn");
}

static void *
check_netconn(lua_State *L, int idx)
{
	struct connbox *box = luaL_checkudata(L, idx, "netconn");

	luaL_argcheck(L, box->conn != NULL, idx, "connection already closed");
	return box->conn;
}

static void *
check_udpconn(lua_State *L, int idx)
{
	struct connbox *box = luaL_checkudata(L, idx, "udpconn");

	luaL_argcheck(L, box->conn != NULL, idx, "connection already closed");
	return box->conn;
}

/* ---- los.platform.tcp ---- */

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

static const luaL_Reg tcplib[] = {
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

int luaopen_los_platform_tcp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	luaL_newmetatable(L, "netconn");
	lua_pushcfunction(L, l_netconn_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newlib(L, tcplib);
	return 1;
}

/* ---- los.platform.udp ---- */

static int
l_udp_open(lua_State *L)
{
	void *c = udp_open((unsigned short)luaL_checkinteger(L, 1));

	if (!c)
		return 0;
	push_udpconn(L, c);
	return 1;
}

static int
l_udp_close(lua_State *L)
{
	return l_udpconn_gc(L);
}

static int
l_udp_cancel(lua_State *L)
{
	udp_cancel(check_udpconn(L, 1));
	return 0;
}

static int
l_udp_send_start(lua_State *L)
{
	void *conn = check_udpconn(L, 1);
	unsigned char octets[4];

	for (int i = 0; i < 4; i++)
		octets[i] = (unsigned char)luaL_checkinteger(L, i + 2);

	unsigned int ip;

	memcpy(&ip, octets, 4);

	unsigned short port = (unsigned short)luaL_checkinteger(L, 6);
	size_t n;
	const char *s = luaL_checklstring(L, 7, &n);
	void *tok = udp_send_start(conn, ip, port, s, n);

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_udp_send_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	lua_pushboolean(L, udp_send_poll(lua_touserdata(L, 1)));
	return 1;
}

static int
l_udp_recv_start(lua_State *L)
{
	void *conn = check_udpconn(L, 1);
	lua_Integer maxlen = luaL_optinteger(L, 2, 4096);
	void *tok = udp_recv_start(conn, (unsigned long)maxlen);

	if (!tok)
		return 0;
	lua_pushlightuserdata(L, tok);
	return 1;
}

static int
l_udp_recv_poll(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);

	void *data = 0;
	unsigned long len = 0;
	unsigned int srcip = 0;
	unsigned short srcport = 0;
	int done = udp_recv_poll(lua_touserdata(L, 1), &data, &len,
	    &srcip, &srcport);

	if (!done) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	if (data) {
		unsigned char octets[4];

		memcpy(octets, &srcip, 4);
		lua_pushlstring(L, data, len);
		free(data);
		lua_pushinteger(L, octets[0]);
		lua_pushinteger(L, octets[1]);
		lua_pushinteger(L, octets[2]);
		lua_pushinteger(L, octets[3]);
		lua_pushinteger(L, srcport);
		return 7;	/* true, data, a, b, c, d, port */
	}
	return 1;	/* done, but error: (true, nil) */
}

static const luaL_Reg udplib[] = {
	{ "open", l_udp_open },
	{ "close", l_udp_close },
	{ "cancel", l_udp_cancel },
	{ "send_start", l_udp_send_start },
	{ "send_poll", l_udp_send_poll },
	{ "recv_start", l_udp_recv_start },
	{ "recv_poll", l_udp_recv_poll },
	{ NULL, NULL }
};

int luaopen_los_platform_udp(lua_State *L);

int
luaopen_los_platform_udp(lua_State *L)
{
	luaL_newmetatable(L, "udpconn");
	lua_pushcfunction(L, l_udpconn_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newlib(L, udplib);
	return 1;
}
