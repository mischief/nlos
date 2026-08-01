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
#include "virtio_9p.h"
#include "virtio_rng.h"

extern void console_write(const char *s, unsigned long n);
extern void uart_tx(const char *s, unsigned long n);
_Noreturn void machine_reset(void);
void platform_stall_us(unsigned long us);

/* ---- los.platform.cons ---- */

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
p9_rpc(lua_State *L)
{
	size_t reqlen;
	const char *req = luaL_checklstring(L, 1, &reqlen);
	size_t repcap = 8192;	/* P9_MSIZE, see virtio_9p.c */
	char *rep = malloc(repcap);

	if (!rep)
		return luaL_error(L, "p9.rpc: out of memory");

	int got = virtio_9p_rpc(req, reqlen, rep, repcap);

	if (got < 0) {
		free(rep);
		return luaL_error(L, "p9.rpc: device read failed");
	}
	lua_pushlstring(L, rep, (size_t)got);
	free(rep);
	return 1;
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
