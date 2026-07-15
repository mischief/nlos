/* the los.efi module: read-only firmware/boot info.
 *
 * no authority lives here on purpose -- actions (console write, reset,
 * stall) are los.platform, registered only for the conio task (see
 * conio.c and kernel.c's spawn_conio). every other proc, including
 * this one's caller, can read firmware/firmware_revision but cannot
 * touch the machine through this module.
 */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

static const luaL_Reg efilib[] = {
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
