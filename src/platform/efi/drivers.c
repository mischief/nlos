/* raw device/platform primitives: console-write, wire-write, and
 * platform power (reset/stall). three separate modules, each
 * registered in package.preload ONLY for its one owning task (see
 * kernel.c's spawn_cons/spawn_wire/spawn_power) -- no other proc's
 * require() can ever see any of these keys. every other proc holds,
 * at most, a send-right to the owning task's mailbox.
 */

#include "efi.h"
#include "rng.h"

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

/* los.platform.rng, from the firmware's EFI_RNG_PROTOCOL (rng.c) where
 * it publishes one -- edk2 does wherever the CPU has RDRAND. microvm's
 * counterpart does the same job from virtio-rng.
 *
 * Probed once and granted to the boot proc only, like cons and wire: a
 * draw conveys no authority, but the raw C function IS the capability
 * (there is no handle to check), so it follows the same rule as every
 * other privileged raw primitive and exists in exactly one proc. What
 * everything else gets is a seed, handed over at spawn as ordinary data.
 */
void
platform_boot_extra_modules(lua_State *L)
{
	static int tried, have_rng;

	if (!tried) {
		have_rng = efi_rng_probe();
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

/* raw ethernet is a microvm affair. This platform gets tcp and udp from
 * the firmware's own EFI_TCP4/EFI_UDP4, so it has no use for frames and
 * no virtio-mmio driver to produce them with. Same empty-symbol
 * arrangement as p9 above.
 */
int
platform_have_eth(void)
{
	return 0;
}

static const luaL_Reg eth_emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_eth(lua_State *L);

int
luaopen_los_platform_eth(lua_State *L)
{
	luaL_newlib(L, eth_emptylib);
	return 1;
}
