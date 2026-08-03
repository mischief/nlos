/* EFI_SIMPLE_NETWORK_PROTOCOL -- the firmware's nic with nothing on top.
 *
 * Frames in, frames out, and the card's address. Everything above that
 * is ours in Lua (lib/ether.lua up through task/tcp4.lua), which is the
 * same stack microvm runs over virtio-net, so both machines run one
 * implementation of arp, ip, icmp, udp and tcp rather than one each.
 *
 * The alternative, and what this replaces, is src/platform/efi/net.c:
 * EFI_TCP4_PROTOCOL and EFI_UDP4_PROTOCOL, where the firmware owns the
 * stack and we drive it through tokens and events. That works, and it
 * is why efi had networking first, but it means two stacks to keep
 * agreeing, protocol behaviour we cannot see or fix, and a dhcp we wait
 * on rather than run.
 *
 * ---- taking the card away from the firmware ----
 *
 * The one thing that must happen before any of this works. Firmware
 * binds its own drivers to the nic at boot -- MNP, then ARP, IP4, DHCP4,
 * TCP4, UDP4 -- and those consume received frames. SNP has a single
 * receive queue and no fan-out, so whoever calls Receive first gets the
 * frame and everyone else never learns it existed.
 *
 * That is the same shape as the bug task/eth.lua was fixed for, one
 * layer down and with no way to fix it from inside: we cannot make the
 * firmware share. So DisconnectController unbinds every driver from the
 * handle, which is what makes the queue ours alone.
 *
 * ---- and why there is still no interrupt ----
 *
 * Receive returns EFI_NOT_READY when the card has nothing; there is no
 * line into an ioapic the way virtio-net has. WaitForPacket is the
 * nearest thing -- an EFI_EVENT the firmware signals when a frame is
 * waiting -- and kernel.c puts it in the wait set so an idle machine
 * sleeps rather than spins. It is not free the way an interrupt is:
 * plenty of SNP drivers implement it with a periodic timer that polls
 * the hardware. But the polling is then the firmware's, on its own
 * clock, and this cpu is halted meanwhile.
 */

#include <stddef.h>
#include <string.h>

#include "efi.h"
#include "lua.h"
#include "lauxlib.h"
#include "snp.h"

static EFI_GUID snp_guid = { 0xA19832B9, 0xAC25, 0x11D3,
	{ 0x9A, 0x2D, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D } };

static EFI_SIMPLE_NETWORK_PROTOCOL *snp;
static unsigned long rx_frames;	/* frames actually taken off the card */
static unsigned long rx_events;	/* times the card said one had arrived */

/* GetStatus has two callers wanting different halves of it -- the pump
 * wants the receive bit, a send wants its buffer back -- and it CLEARS
 * what it reports. Calling it from both places directly means whichever
 * ran first swallowed the other's answer, so it is called in one place
 * and both read from what it saved.
 */
static UINT32 pending_istat;
static int tx_outstanding;

static void
status_poll(void)
{
	UINT32 istat = 0;
	void *tx = 0;

	if (!snp || snp->GetStatus(snp, &istat, &tx) != EFI_SUCCESS)
		return;
	pending_istat |= istat;
	if (tx)
		tx_outstanding = 0;
}

/* One transmit at a time, into a buffer that outlives the call.
 *
 * Transmit is asynchronous: the buffer must stay valid until the card
 * is done with it, and GetStatus hands it back through TxBuf to say so.
 * A caller's Lua string cannot be that buffer -- it may be collected
 * the moment eth.send returns -- so the frame is copied here and the
 * recycle is waited for before the next send reuses it.
 */
static unsigned char txbuf[2048];

/* the largest ethernet frame: 1500 of payload, 14 of header, and the
 * 4-byte fcs the card strips before we ever see it.
 */
#define FRAME_MAX 1514

int
snp_init(void)
{
	EFI_HANDLE *handles = 0;
	UINTN count = 0, i;

	if (snp)
		return 1;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &snp_guid, 0,
	    &count, &handles) != EFI_SUCCESS || count == 0)
		return 0;

	for (i = 0; i < count; i++) {
		EFI_SIMPLE_NETWORK_PROTOCOL *p = 0;

		/* unbind the firmware's own stack first, or it competes
		 * with us for every frame. Failure is not fatal: a handle
		 * nothing was bound to reports one, and is exactly the
		 * handle we want.
		 */
		BS->DisconnectController(handles[i], 0, 0);

		if (BS->HandleProtocol(handles[i], &snp_guid,
		    (void **)&p) != EFI_SUCCESS || !p || !p->Mode)
			continue;

		if (p->Mode->State == EFI_SIMPLE_NETWORK_STOPPED &&
		    p->Start(p) != EFI_SUCCESS)
			continue;

		if (p->Mode->State != EFI_SIMPLE_NETWORK_INITIALIZED &&
		    p->Initialize(p, 0, 0) != EFI_SUCCESS)
			continue;

		/* unicast for us, broadcast for arp and dhcp. Not
		 * promiscuous: lib/inet.lua filters by mac anyway, and
		 * every frame the card hands up is one this proc has to
		 * look at.
		 */
		p->ReceiveFilters(p,
		    EFI_SIMPLE_NETWORK_RECEIVE_UNICAST |
		    EFI_SIMPLE_NETWORK_RECEIVE_BROADCAST, 0, 1, 0, 0);

		snp = p;
		break;
	}

	return snp != 0;
}

void *
snp_wait_event(void)
{
	/* optional in the protocol, so a driver without one is a machine
	 * that has to be polled rather than a machine that cannot work.
	 */
	return snp ? snp->WaitForPacket : 0;
}

int
snp_present(void)
{
	return snp != 0;
}

/* has the card taken a frame since the last look?
 *
 * kernel.c's pump_eth wants a number that changes when the device has
 * done something, which on microvm is the virtio interrupt count. There
 * is no interrupt here, so this asks the card and counts the answers.
 *
 * It must not be "frames we have read": nothing reads until the pump
 * wakes the eth task, and the pump does not wake until this moves, so a
 * counter driven by the receive path would sit at zero forever with the
 * first frame still on the card.
 */
unsigned long
snp_rx_count(void)
{
	status_poll();
	if (pending_istat & EFI_SIMPLE_NETWORK_RECEIVE_INTERRUPT) {
		pending_istat &= ~(UINT32)EFI_SIMPLE_NETWORK_RECEIVE_INTERRUPT;
		rx_events++;
	}
	return rx_events;
}

/* frames actually handed up, for eth.irqs() and for telling "the card
 * saw traffic" apart from "we managed to read it".
 */
unsigned long
snp_rx_frames(void)
{
	return rx_frames;
}

int
snp_mac(unsigned char *out, size_t n)
{
	size_t len;

	if (!snp)
		return 0;
	len = snp->Mode->HwAddressSize;
	if (len > n)
		len = n;
	memcpy(out, snp->Mode->CurrentAddress.Addr, len);
	return (int)len;
}

int
snp_send(const void *frame, size_t n)
{
	int spins;

	if (!snp || n == 0 || n > sizeof txbuf)
		return -1;

	/* wait out the previous transmit before overwriting the buffer it
	 * may still be reading. Bounded: a card that never recycles is a
	 * card that is not going to, and dropping the frame is better than
	 * never returning to the scheduler.
	 */
	for (spins = 0; tx_outstanding && spins < 10000; spins++)
		status_poll();

	memcpy(txbuf, frame, n);

	/* HeaderSize 0 means the buffer already carries its ethernet
	 * header, which it does -- lib/ether.lua built it. Passing the
	 * addresses separately would have the firmware build a second one.
	 */
	if (snp->Transmit(snp, 0, n, txbuf, 0, 0, 0) != EFI_SUCCESS)
		return -1;

	tx_outstanding = 1;
	return 0;
}

int
snp_recv(void *buf, size_t cap)
{
	UINTN size = cap;
	EFI_STATUS st;

	if (!snp)
		return 0;

	st = snp->Receive(snp, 0, &size, buf, 0, 0, 0);
	if (st != EFI_SUCCESS)
		return 0;	/* EFI_NOT_READY, mostly: nothing waiting */

	rx_frames++;
	return (int)size;
}

/* ---- los.platform.eth, the same four calls microvm's drivers.c has ---- */

static int
eth_mac(lua_State *L)
{
	unsigned char mac[6];

	if (snp_mac(mac, sizeof mac) != 6)
		return 0;
	lua_pushlstring(L, (const char *)mac, 6);
	return 1;
}

static int
eth_send(lua_State *L)
{
	size_t n;
	const char *frame = luaL_checklstring(L, 1, &n);

	/* false rather than an error when the card refuses: a caller
	 * pacing itself against the wire is doing something ordinary.
	 */
	lua_pushboolean(L, snp_send(frame, n) == 0);
	return 1;
}

static int
eth_recv(lua_State *L)
{
	char buf[FRAME_MAX];
	int n = snp_recv(buf, sizeof buf);

	if (n <= 0)
		return 0;		/* nil: nothing waiting */
	lua_pushlstring(L, buf, (size_t)n);
	return 1;
}

static int
eth_irqs(lua_State *L)
{
	/* frames, not interrupts: there are none here. The name is the
	 * one microvm's driver uses and the tests read, and what both
	 * answer is "has the device done anything since I last asked".
	 */
	lua_pushinteger(L, (lua_Integer)snp_rx_frames());
	return 1;
}

static const luaL_Reg ethlib[] = {
	{ "mac", eth_mac },
	{ "send", eth_send },
	{ "recv", eth_recv },
	{ "irqs", eth_irqs },
	{ NULL, NULL },
};

int	luaopen_los_platform_eth(lua_State *L);

int
luaopen_los_platform_eth(lua_State *L)
{
	luaL_newlib(L, ethlib);
	return 1;
}
