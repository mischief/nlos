/* the los.fs module: directory enumeration and metadata for the esp.
 *
 * READ-ONLY on purpose, and ambient on purpose. both follow the line
 * already drawn for io.open: disk *read* is deliberately not gated (the
 * threat model is buggy lua rather than hostile users, nothing on the
 * esp is confidentiality-sensitive, and a stray read cannot corrupt a
 * future boot the way a runaway write can), while *write* is gated on a
 * capability. listing a directory is read-class, so it sits on the same
 * side of that line -- and nothing here can create, modify or delete.
 *
 * this is expected to move. once espfs becomes a real exclusive task
 * owning the esp, these belong in a los.platform.espfs registered for
 * that task alone, and every other proc reaches files through a mount
 * instead. that is a refinement, not a prerequisite: a namespace needs
 * enumeration to exist before it can route it. see
 * docs/shell-namespace-draft.md.
 */

#include <stddef.h>

#include "fs.h"

#include "lua.h"
#include "lauxlib.h"

/* los.fs.readdir(path) -> { {name=, size=, dir=}, ... } | nil, err
 *
 * the whole listing is built here rather than handing lua an iterator,
 * so no efi handle is ever reachable from lua and there is nothing to
 * leak if the caller abandons the loop.
 */
static int
l_fs_readdir(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	void *f = fs_open(path, 0);

	if (!f) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot open %s", path);
		return 2;
	}

	struct fs_dirent ent;

	/* Read() on a regular file returns bytes, not records, and would
	 * come back as convincing nonsense -- check what we opened before
	 * enumerating it. see fs_readdir's contract.
	 */
	if (fs_stat(f, &ent) != 0 || !ent.isdir) {
		fs_close(f);
		lua_pushnil(L);
		lua_pushfstring(L, "%s is not a directory", path);
		return 2;
	}

	lua_newtable(L);

	int n = 0, rc;

	while ((rc = fs_readdir(f, &ent)) == 1) {
		lua_createtable(L, 0, 3);
		lua_pushstring(L, ent.name);
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, (lua_Integer)ent.size);
		lua_setfield(L, -2, "size");
		lua_pushboolean(L, ent.isdir);
		lua_setfield(L, -2, "dir");
		lua_rawseti(L, -2, ++n);
	}
	fs_close(f);

	if (rc < 0) {
		lua_pushnil(L);
		lua_pushfstring(L, "error reading %s", path);
		return 2;
	}
	return 1;
}

/* los.fs.stat(path) -> {name=, size=, dir=} | nil, err */
static int
l_fs_stat(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	void *f = fs_open(path, 0);

	if (!f) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot open %s", path);
		return 2;
	}

	struct fs_dirent ent;
	int rc = fs_stat(f, &ent);

	fs_close(f);
	if (rc != 0) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot stat %s", path);
		return 2;
	}
	lua_createtable(L, 0, 3);
	lua_pushstring(L, ent.name);
	lua_setfield(L, -2, "name");
	lua_pushinteger(L, (lua_Integer)ent.size);
	lua_setfield(L, -2, "size");
	lua_pushboolean(L, ent.isdir);
	lua_setfield(L, -2, "dir");
	return 1;
}

static const luaL_Reg fslib[] = {
	{ "readdir", l_fs_readdir },
	{ "stat", l_fs_stat },
	{ NULL, NULL }
};

int luaopen_los_fs(lua_State *L);

int
luaopen_los_fs(lua_State *L)
{
	luaL_newlib(L, fslib);
	return 1;
}
