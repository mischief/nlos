/* the los.efi module: firmware/boot-services bindings.
 *
 * this is the transitional layer -- everything here calls efi boot or
 * runtime services and goes away once we ExitBootServices and own the
 * machine. kernel primitives that outlive efi (ticks, serwrite) live in
 * los.sys, not here.
 */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

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

static const luaL_Reg efilib[] = {
	{ "reset", los_reset },
	{ "stall", los_stall },
	{ NULL, NULL }
};

int luaopen_los_efi(lua_State *L);

int
luaopen_los_efi(lua_State *L)
{
	char vendor[64];
	int i;

	luaL_newlib(L, efilib);

	for (i = 0; i < 63 && ST->FirmwareVendor[i]; i++)
		vendor[i] = (char)ST->FirmwareVendor[i];
	vendor[i] = 0;
	lua_pushstring(L, vendor);
	lua_setfield(L, -2, "firmware");

	lua_pushinteger(L, ST->FirmwareRevision);
	lua_setfield(L, -2, "firmware_revision");

	return 1;
}
