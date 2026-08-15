/* los.platform.{cons,wire,power} and a minimal los.efi, backed by
 * microvm's own uart/console/reset instead of firmware -- see
 * src/platform/efi/drivers.c and src/platform/efi/los.c, which these
 * mirror. registration (which proc gets which module) is unchanged,
 * in kernel.c's proc_new.
 */

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "buf.h"
#include "embedfs.h"
#include "platform.h"
#include "virtio.h"
#include "virtio_9p.h"
#include "virtio_blk.h"
#include "virtio_net.h"
#include "virtio_rng.h"

extern void console_write(const char *s, unsigned long n);
extern void uart_tx(const char *s, unsigned long n);
extern void uart_txlock(void);
extern void uart_txunlock(void);
extern unsigned long uart_rx_irqs(void);
_Noreturn void machine_reset(void);
void platform_stall_us(unsigned long us);

/* what an idle cpu is allowed to wake for: a virtio interrupt, and a
 * byte on the console line. The uart counts because the idle wait
 * watches this and nothing else -- without it a byte wakes the cpu from
 * hlt and it sleeps again until the timer, which paces the console at
 * one read per tick.
 */
unsigned long
platform_dev_irqs(void)
{
	return virtio_irq_count() + uart_rx_irqs();
}

/* nothing: efi_shim's WaitForEvent already halts until an interrupt and
 * watches platform_dev_irqs itself, so a frame wakes this machine
 * without an event to name.
 */
void *
platform_dev_wait(void)
{
	return 0;
}

/* ---- los.platform.cons ---- */

/* com1 is the console's keyboard and the 9p wire both, and a byte can
 * only be delivered once. Until the console claims it, kernel.c's
 * pump_serial drains it to the wire exactly as before -- which is what
 * test/boot/microvm_serialrx.lua measures, and why this is not simply
 * switched on. The console driver claims it when the boot payload tells
 * it to (lib/cons.lua's claim_input op), and from then on the bytes
 * reach efi_shim's ReadKeyStroke and so the cons task's line editor.
 */
static int console_owns_input;

int
platform_console_input(void)
{
	return console_owns_input;
}

static int
cons_claim_input(lua_State *L)
{
	console_owns_input = 1;
	(void)L;
	return 0;
}

static int
cons_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	console_write(s, n);
	return 0;
}

/* cons.raw(on) -- stop translating \n on the way out, so a binary
 * stream survives. lib/console.lua calls this from rawon/rawoff.
 */
static int
cons_raw(lua_State *L)
{
	console_setraw(lua_toboolean(L, 1));
	return 0;
}

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
	{ "raw", cons_raw },
	{ "claim_input", cons_claim_input },
	{ NULL, NULL }
};

int luaopen_los_platform_cons(lua_State *L);

int
luaopen_los_platform_cons(lua_State *L)
{
	luaL_newlib(L, conslib);
	return 1;
}

/* ---- los.platform.wire ---- */

static int
wire_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	/* the wire's bytes are a protocol frame; nothing may be
	 * interleaved into them by a console write on another cpu
	 */
	uart_txlock();
	uart_tx(s, n);
	uart_txunlock();
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

/* ---- los.platform.power ---- */

static int
power_reset(lua_State *L)
{
	(void)L;
	machine_reset();	/* triple fault; -no-reboot exits qemu */
}

static int
power_stall(lua_State *L)
{
	platform_stall_us((unsigned long)luaL_checkinteger(L, 1));
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

/* ---- los.efi: no firmware here, but the host's fw_cfg is read the
 * same way, so init.lua reads a services list out of it on this machine
 * exactly as it does on one with firmware. Grants nothing: fw_cfg is
 * read-only data the host handed us at boot.
 */
int	fwcfg_load(const char *name, char **buf, size_t *len);

static int
l_efi_fwcfg(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	char *buf = 0;
	size_t len = 0;

	if (fwcfg_load(name, &buf, &len) != 0)
		return 0;
	lua_pushlstring(L, buf, len);
	free(buf);
	return 1;
}

static const luaL_Reg efilib[] = {
	{ "fwcfg", l_efi_fwcfg },
	{ NULL, NULL }
};

int luaopen_los_efi(lua_State *L);

int
luaopen_los_efi(lua_State *L)
{
	luaL_newlib(L, efilib);
	return 1;
}

/* ---- los.platform.rng: virtio-rng, if one is present ---- */

#define RNG_MAX_BYTES 65536	/* one request's worth; no reason for more */

static int
rng_bytes(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);

	if (n < 0 || n > RNG_MAX_BYTES)
		return luaL_error(L, "rng.bytes: n out of range (0-%d)",
		    RNG_MAX_BYTES);

	char *buf = malloc((size_t)n);

	if (n > 0 && !buf)
		return luaL_error(L, "rng.bytes: out of memory");

	int got = virtio_rng_read(buf, (size_t)n);

	if (got < 0) {
		free(buf);
		return luaL_error(L, "rng.bytes: device read failed");
	}
	lua_pushlstring(L, buf, (size_t)got);
	free(buf);
	return 1;
}

static const luaL_Reg rnglib[] = {
	{ "bytes", rng_bytes },
	{ NULL, NULL }
};

int luaopen_los_platform_rng(lua_State *L);

int
luaopen_los_platform_rng(lua_State *L)
{
	luaL_newlib(L, rnglib);
	return 1;
}

/* ---- los.platform.p9: virtio-9p transport, if one is present ----
 * pure transport -- one request in, one reply out. lib/ninep.lua's
 * client-side T-message builders and R-message decode (M.decode's
 * Rversion/Rattach/... branches) are the policy layer on top; see
 * AGENTS.md "C is mechanism, Lua is policy".
 */

static int
p9_rpc_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;

	/* ctx carries the slot across the yields, biased by one so that
	 * zero can mean "not started yet" -- either this is the first
	 * attempt, or every slot was busy when we last tried.
	 */
	if (ctx == 0) {
		size_t reqlen;
		const char *req = luaL_checklstring(L, 1, &reqlen);
		int slot;

		if (reqlen > 8192)	/* P9_MSIZE, see virtio_9p.c */
			return luaL_error(L, "p9.rpc: message too large");

		slot = virtio_9p_start(req, reqlen);
		if (slot < 0)
			/* window full: let the outstanding ones drain */
			return lua_yieldk(L, 0, 0, p9_rpc_k);
		ctx = (lua_KContext)(slot + 1);
	}

	const void *rep;
	int got = virtio_9p_poll((int)ctx - 1, &rep);

	if (got < 0)
		return lua_yieldk(L, 0, ctx, p9_rpc_k);

	/* a buffer, so the reply's payload reaches the caller as a view
	 * rather than a string cut out of it. Copied before the lua
	 * object exists: `rep` is the device's slot, and making one can
	 * collect, which can run a finalizer that starts another rpc.
	 */
	void *p = luabuf_alloc((size_t)got);

	if (!p)
		return luaL_error(L, "p9.rpc: no room for %d bytes", got);
	memcpy(p, rep, (size_t)got);
	if (!luabuf_give(L, p, (size_t)got)) {
		luabuf_free(p, (size_t)got);
		return luaL_error(L, "p9.rpc: no room for %d bytes", got);
	}
	return 1;
}

/* yields rather than spinning, which is why it is written as a
 * continuation. Scheduling here is cooperative and single threaded, so
 * busy-waiting for the device would stop every other proc as well --
 * and a mounted 9p filesystem does a round trip per walk, read and
 * clunk. Yielding leaves this proc runnable and lets the rest of the
 * machine make progress between polls.
 *
 * Safe to yield from here because this is called as an ordinary Lua
 * function from a proc's coroutine. The same would not be true from a
 * package.preload opener, which loadlib.c invokes with a plain
 * lua_call.
 */
static int
p9_rpc(lua_State *L)
{
	return p9_rpc_k(L, LUA_OK, 0);
}

static int
p9_tag(lua_State *L)
{
	char buf[256];
	int n = virtio_9p_tag(buf, sizeof buf);

	if (n < 0)
		return luaL_error(L, "p9.tag: device read failed");
	lua_pushlstring(L, buf, (size_t)n);
	return 1;
}

static const luaL_Reg p9lib[] = {
	{ "rpc", p9_rpc },
	{ "tag", p9_tag },
	{ NULL, NULL }
};

int luaopen_los_platform_p9(lua_State *L);

int
luaopen_los_platform_p9(lua_State *L)
{
	luaL_newlib(L, p9lib);
	return 1;
}

/* probed once, lazily -- spawn_init only ever calls this for the one
 * boot payload proc, but "once" is cheap insurance either way. rng has
 * no owning driver task (it's a single synchronous call, not a
 * protocol worth a dedicated proc, unlike p9 -- see platform_have_p9
 * below and kernel.c's PRIV_P9), so it stays a direct boot-proc grant.
 */
void
platform_boot_extra_modules(lua_State *L)
{
	static int tried, have_rng;

	if (!tried) {
		have_rng = (virtio_rng_init() == 0);
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

/* virtio_9p_init() itself is idempotent-safe to call once and cache;
 * kernel_init() calls this (via platform_have_p9) before spawn_init
 * ever runs, so by the time PRIV_P9 is decided the probe has already
 * happened.
 */
int
platform_have_p9(void)
{
	static int tried, present;

	if (!tried) {
		present = (virtio_9p_init() == 0);
		tried = 1;
	}
	return present;
}

/* com2 is the wire (com1 being console and keyboard both). There is no
 * EFI System Partition here -- no firmware to have one -- so espsrv is
 * not embedded either, and before this probe existed it was spawned
 * anyway and died on the missing file, burning a pid every boot.
 */
int
platform_have_wire(void)
{
	return 1;
}

int
platform_have_esp(void)
{
	return 0;
}

/* ---- los.platform.eth: virtio-net, raw frames ----
 *
 * Frames and a mac address, and nothing above them. There is no
 * firmware stack to inherit here as there is on efi, so arp, ip, icmp
 * and udp all have to be written -- and they go in Lua. This is the
 * whole of the C side.
 */

static int
eth_mac(lua_State *L)
{
	unsigned char mac[6];

	if (virtio_net_mac(mac) != 0)
		return 0;		/* nil: the device offered none */
	lua_pushlstring(L, (const char *)mac, sizeof mac);
	return 1;
}

static int
eth_send(lua_State *L)
{
	size_t n;
	const char *frame = luabuf_check(L, 1, &n);

	/* false rather than an error when the queue is full: a caller
	 * pacing itself against the wire is doing something ordinary, not
	 * failing.
	 */
	lua_pushboolean(L, virtio_net_send(frame, n) == 0);
	return 1;
}

static int
eth_recv(lua_State *L)
{
	char buf[1514];
	int n = virtio_net_recv(buf, sizeof buf);

	if (n <= 0)
		return 0;		/* nil: nothing waiting, or oversized */
	lua_pushlstring(L, buf, (size_t)n);
	return 1;
}

/* how many virtio interrupts the machine has taken. Exposed so a test
 * can tell a routed line from a dead one -- polling works either way,
 * which is exactly what makes the difference invisible otherwise.
 */
static int
eth_irqs(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)virtio_irq_count());
	return 1;
}

static const luaL_Reg ethlib[] = {
	{ "mac", eth_mac },
	{ "send", eth_send },
	{ "recv", eth_recv },
	{ "irqs", eth_irqs },
	{ NULL, NULL }
};

int luaopen_los_platform_eth(lua_State *L);

int
luaopen_los_platform_eth(lua_State *L)
{
	luaL_newlib(L, ethlib);
	return 1;
}

int
platform_have_eth(void)
{
	static int tried, present;

	if (!tried) {
		present = (virtio_net_init() == 0);
		tried = 1;
	}
	return present;
}

/* ---- los.platform.blk: virtio-blk, raw sectors ----
 *
 * Sectors and a capacity, and nothing above them: no partitions, no
 * filesystem, no notion of what any of these bytes mean. lib/blkfs.lua
 * turns this into a dev backend and a filesystem would go above that --
 * C is mechanism, Lua is policy, and a block device is about as pure a
 * case of the split as this tree has.
 */

static int
blk_capacity(lua_State *L)
{
	if (!virtio_blk_present())
		return 0;		/* nil: no device */
	lua_pushinteger(L, (lua_Integer)virtio_blk_capacity());
	lua_pushinteger(L, VIRTIO_BLK_SECTOR);
	return 2;
}

/* read and write yield rather than spin, for the reason spelled out
 * over p9_rpc above: scheduling here is cooperative and single
 * threaded, so busy-waiting on the device would stop every other proc
 * as well. The slot rides across the yields in the continuation
 * context, biased by one so zero can mean "not started yet" -- either
 * this is the first attempt or every slot was busy when we last tried.
 *
 * The arguments stay on the stack across a yield, so the first branch
 * is the only one that has to look at them.
 */
static int
blk_read_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;

	if (ctx == 0) {
		lua_Integer lba = luaL_checkinteger(L, 1);
		lua_Integer nsec = luaL_checkinteger(L, 2);
		int slot;

		if (lba < 0)
			return luaL_error(L, "blk.read: negative sector");
		if (nsec <= 0 ||
		    nsec > VIRTIO_BLK_MAXIO / VIRTIO_BLK_SECTOR)
			return luaL_error(L, "blk.read: bad sector count");

		slot = virtio_blk_start(0, (uint64_t)lba, 0,
		    (uint32_t)nsec * VIRTIO_BLK_SECTOR);
		if (slot < 0) {
			/* the window being full is not an error -- let the
			 * outstanding requests drain and try again. A
			 * request the device could never accept was already
			 * rejected above, so this is the only case left.
			 */
			if (!virtio_blk_present())
				return luaL_error(L, "blk.read: no device");
			return lua_yieldk(L, 0, 0, blk_read_k);
		}
		ctx = (lua_KContext)(slot + 1);
	}

	const void *data;
	uint32_t len;
	int st = virtio_blk_poll((int)ctx - 1, &data, &len);

	if (st < 0)
		return lua_yieldk(L, 0, ctx, blk_read_k);
	if (st != 0)
		return luaL_error(L, "blk.read: device status %d", st);

	/* a buffer, so the sectors can be given to whoever asked for them
	 * rather than copied there. A string would be copied again by the
	 * serializer and once more by the client.
	 *
	 * The copy happens before the lua object exists. `data` is the
	 * device's slot, and making a lua object can collect, which runs
	 * finalizers, which may reach this driver and start a transfer
	 * into that same slot.
	 */
	void *p = luabuf_alloc((size_t)len);

	if (!p)
		return luaL_error(L, "blk.read: no room for %d bytes",
		    (int)len);
	memcpy(p, data, (size_t)len);
	if (!luabuf_give(L, p, (size_t)len)) {
		luabuf_free(p, (size_t)len);
		return luaL_error(L, "blk.read: no room for %d bytes",
		    (int)len);
	}
	return 1;
}

static int
blk_read(lua_State *L)
{
	return blk_read_k(L, LUA_OK, 0);
}

static int
blk_write_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;

	if (ctx == 0) {
		lua_Integer lba = luaL_checkinteger(L, 1);
		size_t n;
		const char *data = luabuf_check(L, 2, &n);
		int slot;

		if (lba < 0)
			return luaL_error(L, "blk.write: negative sector");
		if (n == 0 || n % VIRTIO_BLK_SECTOR != 0)
			return luaL_error(L,
			    "blk.write: not a whole number of sectors");
		if (n > VIRTIO_BLK_MAXIO)
			return luaL_error(L, "blk.write: too large");

		slot = virtio_blk_start(1, (uint64_t)lba, data, (uint32_t)n);
		if (slot < 0) {
			if (!virtio_blk_present())
				return luaL_error(L, "blk.write: no device");
			return lua_yieldk(L, 0, 0, blk_write_k);
		}
		ctx = (lua_KContext)(slot + 1);
	}

	uint32_t len;
	int st = virtio_blk_poll((int)ctx - 1, 0, &len);

	if (st < 0)
		return lua_yieldk(L, 0, ctx, blk_write_k);
	if (st != 0)
		return luaL_error(L, "blk.write: device status %d", st);

	lua_pushinteger(L, (lua_Integer)len);
	return 1;
}

static int
blk_write(lua_State *L)
{
	return blk_write_k(L, LUA_OK, 0);
}

static const luaL_Reg blklib[] = {
	{ "capacity", blk_capacity },
	{ "read", blk_read },
	{ "write", blk_write },
	{ NULL, NULL }
};

int luaopen_los_platform_blk(lua_State *L);

int
luaopen_los_platform_blk(lua_State *L)
{
	luaL_newlib(L, blklib);
	return 1;
}

int
platform_have_blk(void)
{
	static int tried, present;

	if (!tried) {
		present = (virtio_blk_init() == 0);
		tried = 1;
	}
	return present;
}

/* No flash partition here: storage is a virtio disk, and it reaches Lua
 * through platform_have_blk above. luaopen_los_platform_flash is never
 * called, because nothing is ever granted PRIV_FLASH -- but the symbol
 * has to exist for the link.
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

/* not implemented, and NOT because this machine cannot have a display.
 * `-device virtio-gpu-device` is the virtio-mmio spelling of virtio-gpu
 * and qemu attaches it to microvm's mmio bus quite happily (measured:
 * it lands on virtio-mmio-bus.23), so the register scan in virtio.c
 * could find one the same way it finds 9p and rng. what is missing is
 * the driver.
 *
 * worth knowing before writing it: virtio-gpu is the nicer backend of
 * the two, not the harder one. RESOURCE_ATTACH_BACKING puts the pixels
 * in OUR memory, so unload, fill and scroll all become local reads and
 * memmoves, and only load costs a TRANSFER_TO_HOST_2D plus a
 * RESOURCE_FLUSH over the damaged rectangle. GOP is the awkward one,
 * where every pixel that moves does so behind a firmware call.
 *
 * same empty-symbol arrangement the efi side uses for p9 and eth: the
 * switch in proc_new takes the address unconditionally, so the symbol
 * must link even though no task is ever spawned with the priv that
 * would reach it.
 */
int
platform_have_fb(void)
{
	return 0;
}

static const luaL_Reg fb_emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_fb(lua_State *L);

int
luaopen_los_platform_fb(lua_State *L)
{
	luaL_newlib(L, fb_emptylib);
	return 1;
}

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

/* No pointing device on this platform. A machine with none reports
 * none, and the kernel creates no port for it -- so nothing above can
 * be handed a right to a mouse that does not exist.
 */
int
platform_have_ptr(void)
{
	return 0;
}

int
platform_ptr_read(int *x, int *y, int *buttons)
{
	(void)x;
	(void)y;
	(void)buttons;
	return 0;
}

/* los.rom: the embedded set as data, so lib/romfs.lua can mount it as
 * this machine's root. require() already loads these bytes through
 * luaL_loadfile, below the lua-level io stripping; what this adds is
 * listing them and reading one without executing it. No authority
 * require does not already have: the set is fixed at build time.
 */
static int
rom_list(lua_State *L)
{
	lua_createtable(L, (int)embedfs_nfiles, 0);
	for (size_t i = 0; i < embedfs_nfiles; i++) {
		lua_pushstring(L, embedfs_files[i].path);
		lua_rawseti(L, -2, (lua_Integer)i + 1);
	}
	return 1;
}

static const struct embedfile *
rom_find(const char *path)
{
	for (size_t i = 0; i < embedfs_nfiles; i++)
		if (strcmp(embedfs_files[i].path, path) == 0)
			return &embedfs_files[i];
	return 0;
}

/* the whole file: these are source measured in kilobytes, so a partial
 * read would buy nothing and add a place to get wrong.
 */
static int
rom_read(lua_State *L)
{
	const struct embedfile *f = rom_find(luaL_checkstring(L, 1));

	if (!f)
		return 0;
	lua_pushlstring(L, (const char *)f->data, f->len);
	return 1;
}

static int
rom_size(lua_State *L)
{
	const struct embedfile *f = rom_find(luaL_checkstring(L, 1));

	if (!f)
		return 0;
	lua_pushinteger(L, (lua_Integer)f->len);
	return 1;
}

static const luaL_Reg romlib[] = {
	{ "list", rom_list },
	{ "read", rom_read },
	{ "size", rom_size },
	{ NULL, NULL }
};

int luaopen_los_rom(lua_State *L);

int
luaopen_los_rom(lua_State *L)
{
	luaL_newlib(L, romlib);
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
