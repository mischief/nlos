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

	if (!c)
		return 0;
	memset(&cfg, 0, sizeof cfg);
	cfg.AccessPoint.UseDefaultAddress = 1;
	cfg.AccessPoint.StationPort = port;
	cfg.AccessPoint.ActiveFlag = 0;
	if (c->tcp->Configure(c->tcp, &cfg) != EFI_SUCCESS) {
		tcp4_sb->DestroyChild(tcp4_sb, c->handle);
		free(c);
		return 0;
	}
	return c;
}

void *
net_dial(unsigned int ipv4be, unsigned short port)
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
	return c;
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
	if (BS->CreateEvent(0, TPL_CALLBACK, 0, 0,
	    &tok->CompletionToken.Event) != EFI_SUCCESS) {
		free(tok);
		return 0;
	}
	if (c->tcp->Accept(c->tcp, tok) != EFI_SUCCESS) {
		BS->CloseEvent(tok->CompletionToken.Event);
		free(tok);
		return 0;
	}
	kernel_register_wait_event(tok->CompletionToken.Event);
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

	kernel_unregister_wait_event(tok->CompletionToken.Event);
	BS->CloseEvent(tok->CompletionToken.Event);

	if (tok->CompletionToken.Status != EFI_SUCCESS) {
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

	if (!tok || !td) {
		free(tok);
		free(td);
		return 0;
	}
	memset(tok, 0, sizeof *tok);
	td->Push = 1;
	td->Urgent = 0;
	td->DataLength = n;
	td->FragmentCount = 1;
	td->FragmentTable[0].FragmentLength = n;
	td->FragmentTable[0].FragmentBuffer = (void *)data;
	tok->Packet.TxData = td;

	if (BS->CreateEvent(0, TPL_CALLBACK, 0, 0,
	    &tok->CompletionToken.Event) != EFI_SUCCESS) {
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
	kernel_register_wait_event(tok->CompletionToken.Event);
	return tok;
}

int
net_send_poll(void *token)
{
	EFI_TCP4_IO_TOKEN *tok = token;

	if (BS->CheckEvent(tok->CompletionToken.Event) != EFI_SUCCESS)
		return 0;
	kernel_unregister_wait_event(tok->CompletionToken.Event);
	BS->CloseEvent(tok->CompletionToken.Event);
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

	if (BS->CreateEvent(0, TPL_CALLBACK, 0, 0,
	    &tok->CompletionToken.Event) != EFI_SUCCESS) {
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
	kernel_register_wait_event(tok->CompletionToken.Event);
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
	kernel_unregister_wait_event(tok->CompletionToken.Event);
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

	c->tcp->Configure(c->tcp, 0);
	tcp4_sb->DestroyChild(tcp4_sb, c->handle);
	free(c);
}
