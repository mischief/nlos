/* raw device/platform primitives: console-write, wire-write, and
 * platform power (reset/stall). three separate modules, each
 * registered in package.preload ONLY for its one owning task (see
 * kernel.c's spawn_cons/spawn_wire/spawn_power) -- no other proc's
 * require() can ever see any of these keys. every other proc holds,
 * at most, a send-right to the owning task's mailbox.
 */

#include "efi.h"
#include "rng.h"

#include "lua.h"
#include "lauxlib.h"

#include "snp.h"
#include "blk.h"
#include "buf.h"
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

/* qemu publishes this for -device usb-tablet and nothing else, so the
 * device decides whether the window system starts.
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
