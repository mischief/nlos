/* raw device and platform primitives: console write, wire write, and
 * power. Each is a separate module, preloaded for its one owning task
 * alone, so no other proc can require any of these keys. Every other
 * proc holds at most a send right to the owning task's mailbox.
 */

#include "efi.h"
#include "rng.h"

#include "lua.h"
#include "lauxlib.h"

#include "snp.h"
#include "blk.h"
#include "buf.h"
#include "kernel.h"
#include "platform.h"

extern void console_write(const char *s, unsigned long n);
extern void uart_tx(const char *s, unsigned long n);

/* ---- los.platform.cons: console (com1) write ---- */

static int
cons_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	console_write(s, n);
	return 0;
}

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
	{ NULL, NULL }
};

int luaopen_los_platform_cons(lua_State *L);

int
luaopen_los_platform_cons(lua_State *L)
{
	luaL_newlib(L, conslib);
	return 1;
}

/* ---- los.platform.wire: 9p wire (com2) write ---- */

static int
wire_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	uart_tx(s, n);
	return 0;
}

static const luaL_Reg wirelib[] = {
	{ "write", wire_write },
	{ NULL, NULL }
};

int luaopen_los_platform_wire(lua_State *L);

int
luaopen_los_platform_wire(lua_State *L)
{
	luaL_newlib(L, wirelib);
	return 1;
}

/* ---- los.platform.power: reset/stall ---- */

static int
power_reset(lua_State *L)
{
	static const char *const modes[] =
	    { "cold", "warm", "shutdown", NULL };
	static const EFI_RESET_TYPE types[] =
	    { EfiResetCold, EfiResetWarm, EfiResetShutdown };
	int opt = luaL_checkoption(L, 1, "cold", modes);

	ST->RuntimeServices->ResetSystem(types[opt], EFI_SUCCESS, 0, 0);
	return 0;	/* unreachable */
}

static int
power_stall(lua_State *L)
{
	BS->Stall((UINTN)luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg powerlib[] = {
	{ "reset", power_reset },
	{ "stall", power_stall },
	{ NULL, NULL }
};

int luaopen_los_platform_power(lua_State *L);

int
luaopen_los_platform_power(lua_State *L)
{
	luaL_newlib(L, powerlib);
	return 1;
}

/* los.platform.rng, from the firmware's EFI_RNG_PROTOCOL (rng.c) where
 * it publishes one -- edk2 does wherever the CPU has RDRAND. microvm's
 * counterpart does the same job from virtio-rng.
 *
 * Probed once and granted to the boot proc only, like cons and wire: a
 * draw conveys no authority, but the raw C function IS the capability
 * (there is no handle to check), so it follows the same rule as every
 * other privileged raw primitive and exists in exactly one proc. What
 * everything else gets is a seed, handed over at spawn as ordinary data.
 */
void
platform_boot_extra_modules(lua_State *L)
{
	static int tried, have_rng;

	if (!tried) {
		have_rng = efi_rng_probe();
		tried = 1;
	}

	if (!have_rng)
		return;

	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");
	lua_pushcfunction(L, luaopen_los_platform_rng);
	lua_setfield(L, -2, "los.platform.rng");
	lua_pop(L, 2);
}

int
platform_have_p9(void)
{
	return 0;
}

/* the firmware gives us com2 for the wire and the ESP for storage, which
 * is the platform this pair of probes was originally written to assume.
 */
int
platform_have_wire(void)
{
	return 1;
}

int
platform_have_esp(void)
{
	return 1;
}

/* the switch in kernel.c's proc_new takes this address unconditionally
 * for PRIV_P9, which is never actually granted here (platform_have_p9
 * above is always 0) -- but the symbol still has to exist to link.
 */
static const luaL_Reg p9_emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_p9(lua_State *L);

int
luaopen_los_platform_p9(lua_State *L)
{
	luaL_newlib(L, p9_emptylib);
	return 1;
}

/* no block device here yet, and unlike p9 above that is a gap rather
 * than a property of the platform. The firmware has
 * EFI_BLOCK_IO_PROTOCOL and this is where a shim over it would go --
 * same surface as microvm's virtio_blk, with lib/blkfs.lua unchanged
 * above it. What makes that more than a port is the ESP: while boot
 * services are alive the firmware holds that media too, so the first
 * target has to be a second, non-boot volume.
 *
 * Same empty-symbol arrangement as p9 above.
 */
int
platform_have_blk(void)
{
	return efi_blk_present();
}

/* No flash partition here: storage on this machine is a disk, and it
 * reaches Lua through platform_have_blk above. luaopen_los_platform_flash
 * is never called, because nothing is ever granted PRIV_FLASH -- but the
 * symbol has to exist for the link.
 */
int
platform_have_flash(void)
{
	return 0;
}

int luaopen_los_platform_flash(lua_State *L);

int
luaopen_los_platform_flash(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

/* ---- los.platform.blk: EFI_BLOCK_IO, raw sectors ----
 *
 * The same surface virtio_blk gives on microvm, minus the yielding:
 * firmware ReadBlocks/WriteBlocks are synchronous, so there is nothing to
 * wait on and no slot to carry across a yield. Sectors and a capacity;
 * lib/blkfs.lua turns this into /data and the gpt parser and gefs go
 * above, none of it changed from the microvm path.
 */

/* a ceiling on one transfer, in the spirit of microvm's VIRTIO_BLK_MAXIO:
 * bound what a single call allocates rather than trust the count.
 * blkfs.lua splits larger reads itself, and never asks for more than its
 * own 32-sector step.
 */
#define EFI_BLK_MAXSEC 256

static int
blk_capacity(lua_State *L)
{
	if (!efi_blk_present())
		return 0;		/* nil: no device */
	lua_pushinteger(L, (lua_Integer)efi_blk_sectors());
	lua_pushinteger(L, (lua_Integer)efi_blk_secsz());
	return 2;
}

static int
blk_read(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	lua_Integer nsec = luaL_checkinteger(L, 2);
	uint32_t secsz = efi_blk_secsz();
	unsigned char *p;
	size_t len;

	if (lba < 0)
		return luaL_error(L, "blk.read: negative sector");
	if (nsec <= 0 || nsec > EFI_BLK_MAXSEC)
		return luaL_error(L, "blk.read: bad sector count");

	/* a buffer: the reply gives the sectors away rather than copying
	 * them to the client.
	 */
	len = (size_t)nsec * secsz;
	p = luabuf_push(L, len);
	if (!p)
		return luaL_error(L, "blk.read: no room for %d bytes",
		    (int)len);
	if (efi_blk_read((uint64_t)lba, (uint32_t)nsec, (char *)p) != 0)
		return luaL_error(L, "blk.read: device error");
	return 1;
}

static int
blk_write(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luabuf_check(L, 2, &n);
	uint32_t secsz = efi_blk_secsz();

	if (lba < 0)
		return luaL_error(L, "blk.write: negative sector");
	if (n == 0 || secsz == 0 || n % secsz != 0)
		return luaL_error(L,
		    "blk.write: not a whole number of sectors");
	if (n > (size_t)EFI_BLK_MAXSEC * secsz)
		return luaL_error(L, "blk.write: too large");
	if (efi_blk_write((uint64_t)lba, data, (uint32_t)n) != 0)
		return luaL_error(L, "blk.write: device error");
	lua_pushinteger(L, (lua_Integer)(n / secsz));
	return 1;
}

static const luaL_Reg blk_lib[] = {
	{ "capacity", blk_capacity },
	{ "read", blk_read },
	{ "write", blk_write },
	{ NULL, NULL },
};

int luaopen_los_platform_blk(lua_State *L);

int
luaopen_los_platform_blk(lua_State *L)
{
	luaL_newlib(L, blk_lib);
	return 1;
}

/* frames received since boot, which is what pump_eth compares.
 *
 * Not interrupts: there are none to count here. SNP's Receive reports
 * an empty card rather than raising a line, so the receive path counts
 * what it took and this reports that -- the pump only needs a number
 * that changes when the device has done something.
 *
 * The firmware's own tcp4/udp4 completions are still Events that net.c
 * polls itself, deliberately outside kernel_run's wait set (see
 * kernel_new_net_event), and are unrelated to this.
 */
unsigned long
platform_dev_irqs(void)
{
	return snp_rx_count();
}

/* SNP's WaitForPacket, so an idle machine wakes on a frame instead of
 * on the next tick. Optional in the protocol -- a driver without one
 * leaves us polling, which is what returning 0 means here.
 *
 * Nothing else touches this event: the pump asks GetStatus, not
 * CheckEvent, so kernel_run's WaitForEvent is its only observer and
 * there is no signaled state for it to steal.
 */
void *
platform_dev_wait(void)
{
	return snp_wait_event();
}

/* two devices here: the firmware's ConIn is the keyboard and com2 is
 * the wire, so nothing has to choose between them. See platform.h.
 */
int
platform_console_input(void)
{
	return 0;
}

int
platform_have_eth(void)
{
	return snp_init();
}

/* no bluetooth: the firmware publishes no HCI transport, and a usb
 * dongle would want a usb stack we do not have. The module is still
 * defined because proc.c names it on every platform; nothing reaches
 * it, since platform_have_hci keeps the driver from spawning.
 */
int
platform_have_hci(void)
{
	return 0;
}

int
platform_have_lora(void)
{
	return 0;
}

static const luaL_Reg hci_emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_hci(lua_State *L);

int
luaopen_los_platform_hci(lua_State *L)
{
	luaL_newlib(L, hci_emptylib);
	return 1;
}

/* los.platform.eth lives in snp.c on this platform: the firmware's
 * EFI_SIMPLE_NETWORK_PROTOCOL, with our own stack above it.
 */

/* no keyboard of its own: the keys this machine has arrive through the
 * console, which is a different thing (see platform.h).
 */
int
platform_have_kbd(void)
{
	return 0;
}

int
platform_kbd_read(void)
{
	return -1;
}

/* the i8042's mouse, read here rather than through the firmware. The
 * tablet's absolute protocol is nicer but nothing arrives on it: qemu
 * sends pointer input to the PS/2 mouse, and the firmware's usb driver
 * is not serviced while this kernel runs.
 */
/* whether the mouse answered, which the pointer entry points below read
 * on every machine -- so it sits outside the guard. */
static int ps2ok;

/* The controller is a pc device reached through port space, and the arm
 * and riscv virt machines have neither. There the firmware's absolute
 * pointer is the only pointer there is.
 */
#if defined(__x86_64__)

#define I8042_DATA	0x60
#define I8042_STATUS	0x64
#define I8042_CMD	0x64

#define ST_OUTFULL	0x01	/* something to read on 0x60 */
#define ST_INFULL	0x02	/* the controller has not taken ours yet */
#define ST_AUX		0x20	/* and it came from the mouse, not the keys */

static inline unsigned char
inb(unsigned short port)
{
	unsigned char v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static inline void
outb(unsigned short port, unsigned char v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

static int ps2x, ps2y;		/* where we have accumulated to */
static int ps2mid;		/* and whether that has a starting point */
static int ps2wheel;		/* four bytes a packet, not three */
static int ps2wq;		/* wheel clicks owed, signed: negative is up */
static int ps2b;		/* buttons, as last reported */
static unsigned char ps2pkt[4];
static int ps2n;

/* bounded, because a controller that never clears the flag would hang
 * the machine here and this runs inside the kernel's own loop.
 */
static int
ps2wait(unsigned char bit, int want)
{
	for (int i = 0; i < 100000; i++)
		if (!!(inb(I8042_STATUS) & bit) == want)
			return 1;
	return 0;
}

static int
ps2cmd(unsigned char c)
{
	if (!ps2wait(ST_INFULL, 0))
		return 0;
	outb(I8042_CMD, c);
	return 1;
}

/* a byte to the mouse rather than to the controller, which is what the
 * 0xd4 prefix means. The ack is read so it is not mistaken for motion.
 */
static int
ps2aux(unsigned char c)
{
	if (!ps2cmd(0xd4))
		return 0;
	if (!ps2wait(ST_INFULL, 0))
		return 0;
	outb(I8042_DATA, c);
	if (!ps2wait(ST_OUTFULL, 1))
		return 0;
	return inb(I8042_DATA) == 0xfa;
}

static int
ps2_init(void)
{
	unsigned char cfg;

	ps2cmd(0xa8);			/* the mouse port on */

	if (!ps2cmd(0x20) || !ps2wait(ST_OUTFULL, 1))
		return 0;
	cfg = inb(I8042_DATA);
	cfg |= 0x02;			/* its interrupt, which qemu wants */
	cfg &= (unsigned char)~0x20;	/* and the port not disabled */
	if (!ps2cmd(0x60) || !ps2wait(ST_INFULL, 0))
		return 0;
	outb(I8042_DATA, cfg);

	if (!ps2aux(0xf6))		/* defaults */
		return 0;

	/* the knock that asks for a wheel: three sample rates in this
	 * order, after which a mouse that has one answers 3 to 0xf2 and
	 * sends four bytes a packet instead of three.
	 */
	if (ps2aux(0xf3) && ps2aux(200) && ps2aux(0xf3) && ps2aux(100) &&
	    ps2aux(0xf3) && ps2aux(80) && ps2aux(0xf2) &&
	    ps2wait(ST_OUTFULL, 1))
		ps2wheel = inb(I8042_DATA) == 3;

	if (!ps2aux(0xf4))		/* and report */
		return 0;
	return 1;
}

/* A byte is taken only when the status says the mouse sent it: the
 * other source is the keyboard, which the firmware is still reading.
 * The device reports movement rather than position, so the position is
 * accumulated here and clamped to the screen.
 */
static int
ps2_read(int *x, int *y, int *buttons)
{
	UINTN w = 0, h = 0;
	int dx, dy, b, got = 0;

	efi_fb_size(&w, &h);
	if (w == 0 || h == 0)
		return 0;
	if (!ps2mid) {
		ps2x = (int)(w / 2);
		ps2y = (int)(h / 2);
		ps2mid = 1;
	}

	while ((inb(I8042_STATUS) & (ST_OUTFULL | ST_AUX)) ==
	    (ST_OUTFULL | ST_AUX)) {
		ps2pkt[ps2n++] = inb(I8042_DATA);
		if (ps2n < (ps2wheel ? 4 : 3))
			continue;
		ps2n = 0;

		/* bit 3 is always set in a first byte; without it the
		 * stream is out of step and the packet is dropped rather
		 * than believed.
		 */
		if (!(ps2pkt[0] & 0x08))
			continue;

		dx = ps2pkt[1];
		dy = ps2pkt[2];
		if (ps2pkt[0] & 0x10)
			dx -= 256;
		if (ps2pkt[0] & 0x20)
			dy -= 256;

		ps2x += dx;
		ps2y -= dy;		/* the mouse counts up, screens down */
		got = 1;

		if (ps2wheel && (signed char)ps2pkt[3] != 0)
			ps2wq += (signed char)ps2pkt[3];

		/* a change of button ends the drain, so a press and the
		 * release behind it are two samples. Merged, a click that
		 * lands between two reads is a click nobody saw.
		 */
		b = (ps2pkt[0] & 1) ? 1 : ((ps2pkt[0] & 2) ? 4 : 0);
		if (b != ps2b) {
			ps2b = b;
			break;
		}
	}

	if (!got && ps2wq == 0)
		return 0;

	if (ps2x < 0)
		ps2x = 0;
	if (ps2y < 0)
		ps2y = 0;
	if ((UINTN)ps2x >= w)
		ps2x = (int)w - 1;
	if ((UINTN)ps2y >= h)
		ps2y = (int)h - 1;

	*x = ps2x;
	*y = ps2y;
	*buttons = ps2b;

	/* one click a read, because a wheel event is its own event to a
	 * reader and clicks must not merge. Away from the hand is up.
	 */
	if (ps2wq != 0) {
		*buttons |= ps2wq < 0 ? 8 : 16;
		ps2wq += ps2wq < 0 ? 1 : -1;
	}
	return 1;
}

#else

static int
ps2_init(void)
{
	return 0;
}

static int
ps2_read(int *x, int *y, int *buttons)
{
	(void)x;
	(void)y;
	(void)buttons;
	return 0;
}

#endif

/* absolute position from the firmware, for a machine with a touch panel
 * or a tablet. It is the fallback: qemu leaves it EFI_NOT_READY forever
 * and drives the PS/2 mouse instead.
 */
static EFI_GUID abs_ptr_guid =
    { 0x8d59d32b, 0xc655, 0x4ae9,
      { 0x9b, 0x15, 0xf2, 0x59, 0x04, 0x99, 0x2a, 0x43 } };

static EFI_ABSOLUTE_POINTER_PROTOCOL *absptr;

int
platform_have_ptr(void)
{
	EFI_HANDLE *handles = 0;
	UINTN count = 0;

	if (ps2ok)
		return 1;
	/* the screen is not up yet, so the first read picks the middle */
	if (ps2_init()) {
		ps2ok = 1;
		return 1;
	}

	if (absptr)
		return 1;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &abs_ptr_guid, 0,
	    &count, &handles) != EFI_SUCCESS || count == 0)
		return 0;

	if (BS->HandleProtocol(handles[0], &abs_ptr_guid,
	    (void **)&absptr) != EFI_SUCCESS)
		absptr = 0;

	BS->FreePool(handles);
	if (absptr)
		absptr->Reset(absptr, 0);
	return absptr != 0;
}

/* GetState is EFI_NOT_READY until something moves, which is the poll
 * the pump expects. Scaled here because the device's range is its own.
 */
int
platform_ptr_read(int *x, int *y, int *buttons)
{
	EFI_ABSOLUTE_POINTER_STATE st;
	EFI_ABSOLUTE_POINTER_MODE *md;
	UINTN w = 0, h = 0;
	UINT64 rx, ry;

	if (ps2ok)
		return ps2_read(x, y, buttons);

	if (!absptr || absptr->GetState(absptr, &st) != EFI_SUCCESS)
		return 0;

	md = absptr->Mode;
	rx = (md && md->AbsoluteMaxX > md->AbsoluteMinX) ?
	    md->AbsoluteMaxX - md->AbsoluteMinX : 0;
	ry = (md && md->AbsoluteMaxY > md->AbsoluteMinY) ?
	    md->AbsoluteMaxY - md->AbsoluteMinY : 0;

	efi_fb_size(&w, &h);
	if (rx == 0 || ry == 0 || w == 0 || h == 0)
		return 0;

	*x = (int)(((st.CurrentX - md->AbsoluteMinX) * (UINT64)(w - 1)) / rx);
	*y = (int)(((st.CurrentY - md->AbsoluteMinY) * (UINT64)(h - 1)) / ry);
	/* bit 0 is the touch, which is button 1 here and on the panel */
	*buttons = (st.ActiveButtons & 1) ? 1 : 0;
	return 1;
}

/* the firmware knows about batteries through ACPI, and this machine has
 * no ACPI interpreter to ask with.
 */
int
platform_battery(int *mv)
{
	(void)mv;
	return 0;
}

/* los.rom: no embedded set published here yet. An empty table rather
 * than an absent module, so a caller can ask and get "nothing" instead
 * of a require error -- this platform reaches its files through a
 * filesystem server, which is what los.rom exists to stand in for where
 * there is none.
 */
int luaopen_los_rom(lua_State *L);

int
luaopen_los_rom(lua_State *L)
{
	lua_createtable(L, 0, 0);
	return 1;
}

/* No radio here: this machine's NIC is a wire, with no network to pick.
 * task/eth.lua tests for the calls rather than the module, so an empty
 * table is the answer that means "nothing to associate with".
 */
int luaopen_los_platform_wifi(lua_State *L);

int
luaopen_los_platform_wifi(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

unsigned long
platform_hci_irqs(void)
{
	return 0;
}

/* no tcp from this machine: it has a wire, and lib/tcp4.lua builds the
 * protocol over the frames. The module is empty, for the link.
 */
int
platform_have_net(void)
{
	return 0;
}

int
platform_net_ready(void)
{
	return 0;
}

int luaopen_los_platform_tcp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

int
platform_have_udp(void)
{
	return 0;
}

int luaopen_los_platform_udp(lua_State *L);

int
luaopen_los_platform_udp(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

/* no OTG controller here */
int
platform_usbhost(void)
{
	return 0;
}

int
platform_usb_have(void)
{
	return 0;
}

int
platform_usb_hostattached(void)
{
	return 0;
}

int
platform_usb_desc(void *p, int max)
{
	(void)p;
	(void)max;
	return 0;
}

int
platform_usb_play(int itf, int alt, int ep, int packet, int rate)
{
	(void)itf;
	(void)alt;
	(void)ep;
	(void)packet;
	(void)rate;
	return -1;
}

int
platform_usb_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_usb_stop(void)
{
}

unsigned long
platform_usb_underruns(void)
{
	return 0;
}
/* no amplifier wired to this machine: audio here is a device on a bus
 * or nothing at all.
 */
int
platform_usb_isconsole(void)
{
	return 0;
}

int
platform_i2s_have(void)
{
	return 0;
}

int
platform_i2s_play(int rate, int channels)
{
	(void)rate;
	(void)channels;
	return -1;
}

int
platform_i2s_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_i2s_stop(void)
{
}

unsigned long
platform_i2s_underruns(void)
{
	return 0;
}


/* no websocket here: this machine has sockets, and lib/websocket.lua
 * builds the framing over one. See PRIV_WS.
 */
int
platform_have_ws(void)
{
	return 0;
}

int luaopen_los_platform_ws(lua_State *L);

int
luaopen_los_platform_ws(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

/* no radio here; the symbol exists for the link, as p9's does */
int luaopen_los_platform_lora(lua_State *L);

int
luaopen_los_platform_lora(lua_State *L)
{
	lua_newtable(L);
	return 1;
}
