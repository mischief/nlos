/* raw device/platform primitives: console-write, wire-write, and
 * platform power (reset/stall). three separate modules, each
 * registered in package.preload ONLY for its one owning task (see
 * kernel.c's spawn_cons/spawn_wire/spawn_power) -- no other proc's
 * require() can ever see any of these keys. every other proc holds,
 * at most, a send-right to the owning task's mailbox.
 */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

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

/* microvm's counterpart registers los.platform.rng when a virtio-rng
 * device is present (src/platform/microvm/virtio_rng.c); efi has no
 * such device class yet.
 */
void
platform_boot_extra_modules(lua_State *L)
{
	(void)L;
}

int
platform_have_p9(void)
{
	return 0;
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
