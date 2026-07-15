/* the 'los' table: efi machinery exposed to lua */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

extern unsigned long long platform_ticks(void);

static int
los_ticks(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)platform_ticks());
	return 1;
}

static int
los_reset(lua_State *L)
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
los_stall(lua_State *L)
{
	BS->Stall((UINTN)luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg loslib[] = {
	{ "ticks", los_ticks },
	{ "reset", los_reset },
	{ "stall", los_stall },
	{ NULL, NULL }
};

int
luaopen_los(lua_State *L)
{
	char vendor[64];
	int i;

	luaL_newlib(L, loslib);

	for (i = 0; i < 63 && ST->FirmwareVendor[i]; i++)
		vendor[i] = (char)ST->FirmwareVendor[i];
	vendor[i] = 0;
	lua_pushstring(L, vendor);
	lua_setfield(L, -2, "firmware");

	lua_pushinteger(L, ST->FirmwareRevision);
	lua_setfield(L, -2, "firmware_revision");

	/* well-known right handles. 0 (own receive port) holds for every
	 * proc; 1/2 are the keyboard/serial rights handed to proc 0 at boot.
	 */
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "SELF");
	lua_pushinteger(L, 1);
	lua_setfield(L, -2, "KBD");
	lua_pushinteger(L, 2);
	lua_setfield(L, -2, "SERIAL");

	return 1;
}
