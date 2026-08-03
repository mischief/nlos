/* los.platform.{cons,wire,power} and a minimal los.efi, backed by
 * microvm's own uart/console/reset instead of firmware -- see
 * src/platform/efi/drivers.c and src/platform/efi/los.c, which these
 * mirror. registration (which proc gets which module) is unchanged,
 * in kernel.c's proc_new.
 */

#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"

#include "platform.h"
#include "virtio.h"
#include "virtio_9p.h"
#include "virtio_net.h"
#include "virtio_rng.h"

extern void console_write(const char *s, unsigned long n);
extern void uart_tx(const char *s, unsigned long n);
_Noreturn void machine_reset(void);
void platform_stall_us(unsigned long us);

/* every device interrupt this platform can take is a virtio one: the
 * uart's own line feeds the console through a different path entirely
 * (pump_keyboard, via efi_shim's ReadKeyStroke), and the timer is not
 * a device anyone sleeps on.
 */
unsigned long
platform_dev_irqs(void)
{
	return virtio_irq_count();
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

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
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

/* ---- los.efi: no firmware here, so an empty read-only table ---- */

static const luaL_Reg efilib[] = {
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

	lua_pushlstring(L, rep, (size_t)got);
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
	const char *frame = luaL_checklstring(L, 1, &n);

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
