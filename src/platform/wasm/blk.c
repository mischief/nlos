/* los.platform.blk: the config volume, which is the only storage this
 * machine has. The bytes live wherever the embedder keeps them -- a
 * browser tab keeps them where a reload will find them again -- and
 * this reads and writes sectors of it.
 */

#include <stddef.h>

#include "buf.h"
#include "host.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"
#include "wasm.h"

#define BLK_SECTOR 512
#define BLK_MAXIO  (64 * 1024)

int
platform_have_blk(void)
{
	return host_blk_size() > 0;
}

static int
l_blk_capacity(lua_State *L)
{
	int nsec = host_blk_size();

	if (nsec <= 0)
		return 0;		/* nil: no device */
	lua_pushinteger(L, nsec);
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
	if (host_blk_read((int)lba, p, (int)nsec) != 0) {
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
	if (host_blk_write((int)lba, data, (int)(n / BLK_SECTOR)) != 0)
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
