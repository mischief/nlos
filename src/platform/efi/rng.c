/* los.platform.rng on EFI: EFI_RNG_PROTOCOL, UEFI 2.10 section 37.5.
 *
 * microvm gets this from virtio-rng (src/platform/microvm/virtio_rng.c);
 * the firmware's own protocol is the EFI equivalent, and edk2 publishes
 * it wherever the CPU has RDRAND -- which is every machine this boots on
 * that anyone is using. The Lua-facing shape is deliberately identical:
 * rng.bytes(n) returns exactly n bytes or raises.
 *
 * It raises rather than falling back. There is no weaker source to fall
 * back TO that would be honest: a predictable draw here is not a
 * degraded service, it is a silently broken one, and the caller that
 * wanted entropy has no way to tell. A machine whose firmware publishes
 * no RNG simply has no rng module, which is the same way every other
 * absent capability reports itself here -- see sys.granted().
 */

#include "efi.h"

#include "lua.h"
#include "lauxlib.h"

#include "rng.h"

/* 3152bca5-eade-433d-862e-c01cdc291f44 */
static EFI_GUID rng_guid = { 0x3152bca5, 0xeade, 0x433d,
	{ 0x86, 0x2e, 0xc0, 0x1c, 0xdc, 0x29, 0x1f, 0x44 } };

typedef struct EFI_RNG_PROTOCOL EFI_RNG_PROTOCOL;

struct EFI_RNG_PROTOCOL {
	EFI_STATUS (EFIAPI *GetInfo)(EFI_RNG_PROTOCOL *This,
	    UINTN *RNGAlgorithmListSize, EFI_GUID *RNGAlgorithmList);
	EFI_STATUS (EFIAPI *GetRNG)(EFI_RNG_PROTOCOL *This,
	    EFI_GUID *RNGAlgorithm, UINTN RNGValueLength, UINT8 *RNGValue);
};

static EFI_RNG_PROTOCOL *rng;

/* Located once at boot. LocateProtocol is not in our trimmed
 * EFI_BOOT_SERVICES, so this goes the way uart.c does: enumerate the
 * handles carrying the protocol and take the first that answers.
 */
int
efi_rng_probe(void)
{
	EFI_HANDLE *handles = 0;
	UINTN nhandles = 0;

	if (rng)
		return 1;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &rng_guid, 0,
	    &nhandles, &handles) != EFI_SUCCESS || !handles)
		return 0;

	for (UINTN i = 0; i < nhandles; i++) {
		EFI_RNG_PROTOCOL *p = 0;

		if (BS->HandleProtocol(handles[i], &rng_guid,
		    (void **)&p) == EFI_SUCCESS && p && p->GetRNG) {
			rng = p;
			break;
		}
	}

	return rng != 0;
}

#define RNG_MAX_BYTES 65536	/* one request's worth; no reason for more */

static int
rng_bytes(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);

	if (n < 0 || n > RNG_MAX_BYTES)
		return luaL_error(L, "rng.bytes: n out of range (0-%d)",
		    RNG_MAX_BYTES);
	if (!rng)
		return luaL_error(L, "rng.bytes: no EFI_RNG_PROTOCOL");
	if (n == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	/* luaL_Buffer rather than malloc: the firmware writes straight
	 * into the string being built, so there is no second copy and no
	 * allocation failure path of our own to get wrong.
	 */
	luaL_Buffer b;
	char *buf = luaL_buffinitsize(L, &b, (size_t)n);

	/* A null algorithm asks the firmware for its default, which is
	 * what we want: picking one ourselves would mean asserting
	 * something about the platform we have no way to check.
	 */
	EFI_STATUS st = rng->GetRNG(rng, 0, (UINTN)n, (UINT8 *)buf);

	if (st != EFI_SUCCESS)
		return luaL_error(L, "rng.bytes: GetRNG failed (0x%llx)",
		    (unsigned long long)st);

	luaL_pushresultsize(&b, (size_t)n);
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
