/* tcp4echo: minimal standalone EFI TCP4 accept+echo, deliberately
 * independent of the lua-os kernel/scheduler/notify machinery. built
 * to isolate whether "Accept() never completes despite the wire-
 * level connection genuinely finishing" (see docs/uefi-notes.md's
 * net debugging trail) is a bug in our own tcp4 usage, or something
 * specific to how lua-os's kernel_run drives EFI events. no malloc,
 * no libc, no lua -- just efi.h and BS/ST, busy-polling CheckEvent
 * directly with plain Stall() between checks.
 */

#include "efi.h"

EFI_SYSTEM_TABLE *ST;
EFI_BOOT_SERVICES *BS;
EFI_HANDLE self_image;

static EFI_GUID tcp4_sb_guid = { 0x00720665, 0x67EB, 0x4a99,
	{ 0xBA, 0xF7, 0xD3, 0xC3, 0x3A, 0x1C, 0x7C, 0xC9 } };
static EFI_GUID tcp4_guid = { 0x65530BC7, 0xA359, 0x410f,
	{ 0xB0, 0x10, 0x5A, 0xAD, 0xC7, 0xEC, 0x2B, 0x62 } };

static void
puts16(const char *s)
{
	CHAR16 buf[256];
	int i = 0;

	while (s[i] && i < 255) {
		buf[i] = (CHAR16)(unsigned char)s[i];
		i++;
	}
	buf[i] = 0;
	ST->ConOut->OutputString(ST->ConOut, buf);
}

static void
putstatus(const char *label, EFI_STATUS st)
{
	static const char hex[] = "0123456789abcdef";
	char buf[96];
	int n = 0;

	while (*label)
		buf[n++] = *label++;
	buf[n++] = ':';
	buf[n++] = ' ';
	buf[n++] = '0';
	buf[n++] = 'x';
	for (int shift = 60; shift >= 0; shift -= 4)
		buf[n++] = hex[(st >> shift) & 0xf];
	buf[n++] = '\r';
	buf[n++] = '\n';
	buf[n] = 0;
	puts16(buf);
}

static void
zero(void *p, unsigned long n)
{
	unsigned char *c = p;

	while (n--)
		*c++ = 0;
}

EFI_STATUS
efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	self_image = image;
	ST = st;
	BS = st->BootServices;
	ST->ConOut->ClearScreen(ST->ConOut);
	puts16("tcp4echo: starting\r\n");

	EFI_HANDLE *handles;
	UINTN count;
	EFI_SERVICE_BINDING_PROTOCOL *sb = 0;

	if (BS->LocateHandleBuffer(2, &tcp4_sb_guid, 0, &count, &handles) !=
	    EFI_SUCCESS || count == 0) {
		puts16("no tcp4 service binding found\r\n");
		goto halt;
	}
	for (UINTN i = 0; i < count; i++) {
		if (BS->HandleProtocol(handles[i], &tcp4_sb_guid,
		    (void **)&sb) == EFI_SUCCESS)
			break;
	}
	BS->FreePool(handles);
	if (!sb) {
		puts16("HandleProtocol for service binding failed\r\n");
		goto halt;
	}
	puts16("located tcp4 service binding\r\n");

	EFI_HANDLE child;

	if (sb->CreateChild(sb, &child) != EFI_SUCCESS) {
		puts16("CreateChild failed\r\n");
		goto halt;
	}

	EFI_TCP4_PROTOCOL *tcp;

	if (BS->HandleProtocol(child, &tcp4_guid, (void **)&tcp) !=
	    EFI_SUCCESS) {
		puts16("HandleProtocol for tcp4 failed\r\n");
		goto halt;
	}

	EFI_TCP4_CONFIG_DATA cfg;
	EFI_STATUS cst = 0;
	int tries;

	for (tries = 0; tries < 150; tries++) {
		zero(&cfg, sizeof cfg);
		cfg.AccessPoint.UseDefaultAddress = 1;
		cfg.AccessPoint.StationPort = 7777;
		cfg.AccessPoint.ActiveFlag = 0;
		cst = tcp->Configure(tcp, &cfg);
		if (cst == EFI_SUCCESS)
			break;
		BS->Stall(200000);	/* 0.2s */
	}
	if (cst != EFI_SUCCESS) {
		putstatus("Configure failed", cst);
		goto halt;
	}
	puts16("listening on port 7777\r\n");

	EFI_TCP4_LISTEN_TOKEN atok;

	zero(&atok, sizeof atok);
	if (BS->CreateEvent(0, 0, 0, 0, &atok.CompletionToken.Event) !=
	    EFI_SUCCESS) {
		puts16("CreateEvent for accept failed\r\n");
		goto halt;
	}

	EFI_STATUS ast = tcp->Accept(tcp, &atok);

	putstatus("Accept() returned", ast);
	if (ast != EFI_SUCCESS)
		goto halt;

	puts16("waiting for a connection (up to ~60s)...\r\n");
	for (tries = 0; tries < 6000; tries++) {
		if (BS->CheckEvent(atok.CompletionToken.Event) == EFI_SUCCESS)
			break;
		BS->Stall(10000);	/* 10ms */
	}
	if (tries == 6000) {
		puts16("accept never completed\r\n");
		goto halt;
	}
	putstatus("accept completion status", atok.CompletionToken.Status);
	if (atok.CompletionToken.Status != EFI_SUCCESS)
		goto halt;

	puts16("ACCEPTED a connection!\r\n");

	EFI_TCP4_PROTOCOL *peer;

	if (BS->HandleProtocol(atok.NewChildHandle, &tcp4_guid,
	    (void **)&peer) != EFI_SUCCESS) {
		puts16("HandleProtocol for peer failed\r\n");
		goto halt;
	}

	static char rxbuf[256];
	EFI_TCP4_RECEIVE_DATA rd;
	EFI_TCP4_IO_TOKEN rtok;

	zero(&rtok, sizeof rtok);
	rd.UrgentFlag = 0;
	rd.DataLength = sizeof rxbuf;
	rd.FragmentCount = 1;
	rd.FragmentTable[0].FragmentLength = sizeof rxbuf;
	rd.FragmentTable[0].FragmentBuffer = rxbuf;
	rtok.Packet.RxData = &rd;
	if (BS->CreateEvent(0, 0, 0, 0, &rtok.CompletionToken.Event) !=
	    EFI_SUCCESS) {
		puts16("CreateEvent for recv failed\r\n");
		goto halt;
	}

	EFI_STATUS rst = peer->Receive(peer, &rtok);

	putstatus("Receive() returned", rst);
	if (rst != EFI_SUCCESS)
		goto halt;

	for (tries = 0; tries < 6000; tries++) {
		if (BS->CheckEvent(rtok.CompletionToken.Event) == EFI_SUCCESS)
			break;
		BS->Stall(10000);
	}
	if (tries == 6000) {
		puts16("recv never completed\r\n");
		goto halt;
	}
	putstatus("recv completion status", rtok.CompletionToken.Status);
	if (rtok.CompletionToken.Status != EFI_SUCCESS)
		goto halt;

	puts16("GOT DATA, echoing back\r\n");

	EFI_TCP4_TRANSMIT_DATA td;
	EFI_TCP4_IO_TOKEN ttok;

	zero(&ttok, sizeof ttok);
	td.Push = 1;
	td.Urgent = 0;
	td.DataLength = rtok.Packet.RxData->DataLength;
	td.FragmentCount = 1;
	td.FragmentTable[0].FragmentLength = rtok.Packet.RxData->DataLength;
	td.FragmentTable[0].FragmentBuffer = rxbuf;
	ttok.Packet.TxData = &td;
	if (BS->CreateEvent(0, 0, 0, 0, &ttok.CompletionToken.Event) !=
	    EFI_SUCCESS) {
		puts16("CreateEvent for send failed\r\n");
		goto halt;
	}

	EFI_STATUS tst = peer->Transmit(peer, &ttok);

	putstatus("Transmit() returned", tst);
	if (tst != EFI_SUCCESS)
		goto halt;

	for (tries = 0; tries < 6000; tries++) {
		if (BS->CheckEvent(ttok.CompletionToken.Event) == EFI_SUCCESS)
			break;
		BS->Stall(10000);
	}
	putstatus("send completion status", ttok.CompletionToken.Status);
	puts16("DONE\r\n");

halt:
	puts16("halting.\r\n");
	for (;;)
		BS->Stall(1000000);
}
