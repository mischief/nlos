/* what this machine has, and the los.* modules that go with it. A wasm
 * module has a console and the tree built into it, so cons, power and
 * rom answer yes and every device answers no. The modules behind the
 * absent ones still have to link: proc_new takes their addresses
 * whether or not any task is granted the priv.
 */

#include <stddef.h>
#include <string.h>

#include "embedfs.h"
#include "host.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"
#include "wasm.h"

/* the console is nobody else's: there is no wire here to hold the
 * bytes until a task claims them.
 */
int
platform_console_input(void)
{
	return 1;
}

static int
cons_claim_input(lua_State *L)
{
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

static int
cons_raw(lua_State *L)
{
	console_setraw(lua_toboolean(L, 1));
	return 0;
}

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
	{ "raw", cons_raw },
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

static int
power_reset(lua_State *L)
{
	(void)L;
	machine_halt();
}

static int
power_stall(lua_State *L)
{
	wasm_stall_us((unsigned long)luaL_checkinteger(L, 1));
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

/* the host's entropy, or none. A host that answers no leaves the guest
 * without this module rather than with a predictable one.
 */
static int
rng_bytes(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);
	luaL_Buffer b;
	char *p;

	if (n <= 0 || n > 4096)
		return luaL_error(L, "rng: ask for 1 to 4096 bytes");
	p = luaL_buffinitsize(L, &b, (size_t)n);
	if (!host_random(p, (size_t)n))
		return luaL_error(L, "rng: the host has no entropy");
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

void
platform_boot_extra_modules(lua_State *L)
{
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");
	lua_pushcfunction(L, luaopen_los_platform_rng);
	lua_setfield(L, -2, "los.platform.rng");
	lua_pop(L, 2);
}

/* no directory behind the module: the root is the embedded tree, which
 * init.lua mounts through lib/romfs.lua over los.rom.
 */
int
platform_have_esp(void)
{
	return 0;
}

int
platform_have_wire(void)
{
	return 0;
}

int
platform_have_p9(void)
{
	return 0;
}

int
platform_have_eth(void)
{
	return 0;
}

int
platform_have_net(void)
{
	return 0;
}

int
platform_have_udp(void)
{
	return 0;
}

int
platform_net_ready(void)
{
	return 0;
}

int
platform_have_flash(void)
{
	return 0;
}

int
platform_have_hci(void)
{
	return 0;
}

unsigned long
platform_hci_irqs(void)
{
	return 0;
}

int
platform_battery(int *mv)
{
	(void)mv;
	return 0;
}

/* no interrupts at all: the host's wait is the only thing that ever
 * pauses this machine, and it returns rather than delivers.
 */
unsigned long
platform_dev_irqs(void)
{
	return 0;
}

void *
platform_dev_wait(void)
{
	return NULL;
}

int
platform_usbhost(void)
{
	return 0;
}

int
platform_usb_have(void)
{
	return 0;
}

int
platform_usb_hostattached(void)
{
	return 0;
}

int
platform_usb_desc(void *p, int max)
{
	(void)p;
	(void)max;
	return -1;
}

int
platform_usb_play(int itf, int alt, int ep, int packet, int rate)
{
	(void)itf;
	(void)alt;
	(void)ep;
	(void)packet;
	(void)rate;
	return -1;
}

int
platform_usb_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_usb_stop(void)
{
}

unsigned long
platform_usb_underruns(void)
{
	return 0;
}
/* no amplifier wired to this machine: audio here is a device on a bus
 * or nothing at all.
 */
int
platform_usb_isconsole(void)
{
	return 0;
}

int
platform_i2s_have(void)
{
	return 0;
}

int
platform_i2s_play(int rate, int channels)
{
	(void)rate;
	(void)channels;
	return -1;
}

int
platform_i2s_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_i2s_stop(void)
{
}

unsigned long
platform_i2s_underruns(void)
{
	return 0;
}


static const luaL_Reg emptylib[] = {
	{ NULL, NULL }
};

int luaopen_los_platform_wire(lua_State *L);
int luaopen_los_platform_eth(lua_State *L);
int luaopen_los_platform_flash(lua_State *L);
int luaopen_los_platform_hci(lua_State *L);
int luaopen_los_platform_wifi(lua_State *L);
int luaopen_los_platform_p9(lua_State *L);
int luaopen_los_efi(lua_State *L);
int luaopen_los_rom(lua_State *L);

int
luaopen_los_platform_wire(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_eth(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_flash(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_hci(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_wifi(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_p9(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

/* los.efi: how a machine is handed its boot parameters. There is no
 * channel here for them, so every name answers nothing.
 */
int
luaopen_los_efi(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

/* los.rom: the embedded tree as data, which lib/romfs.lua mounts as the
 * root. No authority require does not already have: the set is fixed at
 * build time.
 */
static const struct embedfile *
rom_find(const char *path)
{
	for (size_t i = 0; i < embedfs_nfiles; i++)
		if (strcmp(embedfs_files[i].path, path) == 0)
			return &embedfs_files[i];
	return NULL;
}

static int
rom_list(lua_State *L)
{
	lua_createtable(L, (int)embedfs_nfiles, 0);
	for (size_t i = 0; i < embedfs_nfiles; i++) {
		lua_pushstring(L, embedfs_files[i].path);
		lua_rawseti(L, -2, (lua_Integer)i + 1);
	}
	return 1;
}

static int
rom_read(lua_State *L)
{
	const struct embedfile *f = rom_find(luaL_checkstring(L, 1));

	if (!f)
		return 0;
	lua_pushlstring(L, (const char *)f->data, f->len);
	return 1;
}

static int
rom_size(lua_State *L)
{
	const struct embedfile *f = rom_find(luaL_checkstring(L, 1));

	if (!f)
		return 0;
	lua_pushinteger(L, (lua_Integer)f->len);
	return 1;
}

static const luaL_Reg romlib[] = {
	{ "list", rom_list },
	{ "read", rom_read },
	{ "size", rom_size },
	{ NULL, NULL }
};

int
luaopen_los_rom(lua_State *L)
{
	luaL_newlib(L, romlib);
	return 1;
}

int luaopen_los_platform_tcp(lua_State *L);
int luaopen_los_platform_udp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}

int
luaopen_los_platform_udp(lua_State *L)
{
	luaL_newlib(L, emptylib);
	return 1;
}
