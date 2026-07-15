/* los.platform: raw console-write and platform-power primitives.
 *
 * registered ONLY for the conio task (see kernel.c's spawn_conio) --
 * no other proc's package.preload ever contains this key, so there is
 * no capability check to get right or forget: the function simply
 * isn't reachable from anywhere else. every other proc holds, at most,
 * a send-right to conio's mailbox and talks to it by message.
 */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

extern void uart_tx(const char *s, unsigned long n);

static int
platform_serwrite(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	uart_tx(s, n);
	return 0;
}

static int
platform_reset(lua_State *L)
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
platform_stall(lua_State *L)
{
	BS->Stall((UINTN)luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg platformlib[] = {
	{ "serwrite", platform_serwrite },
	{ "reset", platform_reset },
	{ "stall", platform_stall },
	{ NULL, NULL }
};

int luaopen_los_platform(lua_State *L);

int
luaopen_los_platform(lua_State *L)
{
	luaL_newlib(L, platformlib);
	return 1;
}
