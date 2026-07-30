/* the los.efi module: read-only firmware/boot info.
 *
 * no authority lives here on purpose -- actions (console write, reset,
 * stall) are los.platform, registered only for the one task that owns
 * each resource. every other proc, including this one's caller, can
 * read firmware info but cannot touch the machine through this module.
 */

#include <string.h>

#include <stdlib.h>

#include "efi.h"
#include "platform.h"

#include "lua.h"
#include "lauxlib.h"

/* parse "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" into an EFI_GUID.
 * returns 0 on success. the mixed endianness is the spec's, not ours:
 * the first three fields are little-endian integers, the last two are
 * a plain byte sequence.
 */
static int
hexval(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* read n hex digits into *out; returns the next position, or 0 on a
 * non-hex digit. hand-rolled rather than growing our libc a sscanf for
 * one caller.
 */
static const char *
hexfield(const char *s, int n, unsigned long long *out)
{
	unsigned long long v = 0;

	for (int i = 0; i < n; i++) {
		int d = hexval(s[i]);

		if (d < 0)
			return 0;
		v = (v << 4) | (unsigned)d;
	}
	*out = v;
	return s + n;
}

static int
parse_guid(const char *s, EFI_GUID *g)
{
	unsigned long long v;

	if (strlen(s) != 36 || s[8] != '-' || s[13] != '-' ||
	    s[18] != '-' || s[23] != '-')
		return -1;

	if (!(s = hexfield(s, 8, &v)))
		return -1;
	g->Data1 = (UINT32)v;
	if (!(s = hexfield(s + 1, 4, &v)))
		return -1;
	g->Data2 = (UINT16)v;
	if (!(s = hexfield(s + 1, 4, &v)))
		return -1;
	g->Data3 = (UINT16)v;

	s++;			/* past the third dash */
	for (int i = 0; i < 8; i++) {
		if (i == 2)
			s++;	/* past the fourth dash */
		if (!(s = hexfield(s, 2, &v)))
			return -1;
		g->Data4[i] = (UINT8)v;
	}
	return 0;
}

/* los.efi.locate(guid) -> number of handles publishing that protocol.
 *
 * read-only, and a count is not a capability: it says whether the
 * firmware has a driver, not that the caller may use it. actually
 * touching a protocol still means a los.platform.* module registered
 * for exactly one owning task. this exists so "does this firmware even
 * have TLS/GOP/HTTP?" is answerable from lua, at the repl, on whatever
 * machine you are actually holding -- rather than by adding C and
 * rebooting, or by grepping a compressed firmware volume and getting a
 * false negative.
 */
static int
l_efi_locate(lua_State *L)
{
	const char *str = luaL_checkstring(L, 1);
	EFI_GUID g;

	if (parse_guid(str, &g) != 0)
		return luaL_error(L, "not a guid: %s", str);

	EFI_HANDLE *handles = 0;
	UINTN count = 0;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &g, 0, &count,
	    &handles) != EFI_SUCCESS) {
		lua_pushinteger(L, 0);
		return 1;
	}
	BS->FreePool(handles);
	lua_pushinteger(L, (lua_Integer)count);
	return 1;
}

/* fwcfg(name) -> the bytes the host put under that name, or nil.
 *
 * belongs here rather than in los.platform because it grants nothing:
 * fw_cfg is read-only data the host handed us at boot, in the same
 * category as the firmware vendor string above. what a proc DOES with
 * it -- init.lua reads /etc/services.lua out of it, so a machine can be
 * configured without touching its disk image -- is policy.
 */
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
	{ "locate", l_efi_locate },
	{ "fwcfg", l_efi_fwcfg },
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
