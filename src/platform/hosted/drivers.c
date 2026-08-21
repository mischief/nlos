/* what this machine has, and the los.* modules that go with it. A linux
 * process has a terminal and a directory, so cons and esp answer yes
 * and the rest answer no. The modules behind the absent ones still have
 * to link: proc_new takes their addresses unconditionally, whether or
 * not any task is granted the priv.
 */

#include <stdlib.h>
#include <string.h>

#include "blk.h"
#include "buf.h"
#include "embedfs.h"
#include "fs.h"
#include "hosted.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"

/* the terminal is the console and nothing else wants it: there is no
 * wire here to hold the bytes until a task claims them.
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
	hosted_stall_us((unsigned long)luaL_checkinteger(L, 1));
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

/* los.efi: how this machine is handed its boot parameters.
 * No firmware, so fwcfg answers from the command line -- the channel
 * qemu's -fw_cfg is elsewhere, read the same way by init.lua and by
 * /etc/services.lua. */
static int
l_efi_fwcfg(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const char *v = hosted_fwcfg(name);

	if (!v)
		return 0;
	lua_pushstring(L, v);
	return 1;
}

static const luaL_Reg efilib[] = {
	{ "fwcfg", l_efi_fwcfg },
	{ NULL, NULL }
};

int luaopen_los_efi(lua_State *L);

int
luaopen_los_efi(lua_State *L)
{
	luaL_newlib(L, efilib);
	return 1;
}

#define RNG_MAX_BYTES 65536

static int
rng_bytes(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);

	if (n < 0 || n > RNG_MAX_BYTES)
		return luaL_error(L, "bad byte count");
	if (n == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	unsigned char *buf = malloc((size_t)n);

	if (!buf)
		return luaL_error(L, "out of memory");

	int ok = hosted_random(buf, (size_t)n) == 0;

	if (ok)
		lua_pushlstring(L, (const char *)buf, (size_t)n);
	free(buf);
	if (!ok)
		return luaL_error(L, "no entropy");
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

/* the boot proc gets the rng directly: it is one synchronous call, not
 * a protocol worth a task of its own.
 */
void
platform_boot_extra_modules(lua_State *L)
{
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");
	lua_pushcfunction(L, luaopen_los_platform_rng);
	lua_setfield(L, -2, "los.platform.rng");
	lua_pop(L, 2);
}

/* the root directory, served by task/espsrv.lua over los.fs: one task
 * owns the host tree and everything else mounts it. With --no-host-fs
 * there is no such tree, so this answers no and init.lua mounts
 * lib/romfs.lua over los.rom instead.
 */
int
platform_have_esp(void)
{
	return !fs_embedded();
}

/* one terminal, and the console has it. */
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
platform_have_blk(void)
{
	return blk_present();
}

static int
l_blk_capacity(lua_State *L)
{
	if (!blk_present())
		return 0;		/* nil: no device */
	lua_pushinteger(L, (lua_Integer)blk_capacity());
	lua_pushinteger(L, BLK_SECTOR);
	return 2;
}

/* a buffer rather than a string: a string would be copied again by the
 * serializer and once more by the client.
 */
static int
l_blk_read(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	lua_Integer nsec = luaL_checkinteger(L, 2);

	if (lba < 0)
		return luaL_error(L, "blk.read: negative sector");
	if (nsec <= 0 || nsec > BLK_MAXIO / BLK_SECTOR)
		return luaL_error(L, "blk.read: bad sector count");

	size_t len = (size_t)nsec * BLK_SECTOR;
	void *p = luabuf_alloc(len);

	if (!p)
		return luaL_error(L, "blk.read: no room for %d bytes", (int)len);
	if (blk_read((unsigned long long)lba, p, (unsigned long)len) != 0) {
		luabuf_free(p, len);
		return luaL_error(L, "blk.read: device error");
	}
	if (!luabuf_give(L, p, len)) {
		luabuf_free(p, len);
		return luaL_error(L, "blk.read: no room for %d bytes", (int)len);
	}
	return 1;
}

static int
l_blk_write(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luabuf_check(L, 2, &n);

	if (lba < 0)
		return luaL_error(L, "blk.write: negative sector");
	if (n == 0 || n % BLK_SECTOR != 0)
		return luaL_error(L, "blk.write: not a whole number of sectors");
	if (n > BLK_MAXIO)
		return luaL_error(L, "blk.write: too large");
	if (blk_readonly())
		return luaL_error(L, "blk.write: the image opened read-only");
	if (blk_write((unsigned long long)lba, data, (unsigned long)n) != 0)
		return luaL_error(L, "blk.write: device error");
	lua_pushinteger(L, (lua_Integer)n);
	return 1;
}

static const luaL_Reg blklib[] = {
	{ "capacity", l_blk_capacity },
	{ "read", l_blk_read },
	{ "write", l_blk_write },
	{ NULL, NULL }
};

int luaopen_los_platform_blk(lua_State *L);

int
luaopen_los_platform_blk(lua_State *L)
{
	luaL_newlib(L, blklib);
	return 1;
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

/* a process runs on the host's power, whatever that is. */
int
platform_battery(int *mv)
{
	(void)mv;
	return 0;
}

/* no device raises anything here: the console is polled, and it is the
 * only device. The idle path sleeps on it directly (clock.c).
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

static const luaL_Reg emptylib[] = { { NULL, NULL } };

int luaopen_los_platform_wire(lua_State *L);
int luaopen_los_platform_eth(lua_State *L);
int luaopen_los_platform_flash(lua_State *L);
int luaopen_los_platform_hci(lua_State *L);
int luaopen_los_platform_wifi(lua_State *L);
int luaopen_los_platform_p9(lua_State *L);
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

/* los.rom: the embedded tree as data, so lib/romfs.lua can mount it as
 * the root of a machine started with --no-host-fs. Where a directory is
 * served instead, the set is still here and romfs is simply not what
 * init.lua mounts. No authority require does not already have: the set
 * is fixed at build time.
 */
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

static const struct embedfile *
rom_find(const char *path)
{
	for (size_t i = 0; i < embedfs_nfiles; i++)
		if (strcmp(embedfs_files[i].path, path) == 0)
			return &embedfs_files[i];
	return 0;
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

/* no OTG controller here */
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
platform_usb_desc(void *p, int max)
{
	(void)p;
	(void)max;
	return 0;
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

