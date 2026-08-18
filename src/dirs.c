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
#include "kernel.h"

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

/* ---- files ----
 *
 * these exist so espfs needs no io.open. espfs is the ESP *driver*: it
 * should reach the platform directly, not through a stdlib that is
 * itself built on the platform. with these, los.fs is the whole of ESP
 * access -- enumeration, metadata and data -- which is what makes it a
 * single thing that can later be handed to one owning task, instead of
 * ESP access being split between here and liolib with no line between
 * them.
 *
 * the handle is a userdata holding fs.c's opaque pointer, so no EFI
 * handle is ever reachable from lua, and __gc closes an abandoned one.
 * that is the same reasoning as readdir building the whole listing
 * rather than handing out an iterator.
 */

#define FSFILE "los.fs.file"

struct fsfile {
	void *f;		/* fs.c handle, NULL once closed */
};

static struct fsfile *
checkfile(lua_State *L)
{
	return (struct fsfile *)luaL_checkudata(L, 1, FSFILE);
}

/* an operation on a closed handle is a caller bug, not an io error */
static void *
openfile(lua_State *L)
{
	struct fsfile *u = checkfile(L);

	if (!u->f)
		luaL_error(L, "attempt to use a closed file");
	return u->f;
}

/* los.fs.open(path, mode) -> file | nil, err
 *
 * mode is "r" or "w". WRITE is gated on the disk capability, exactly as
 * fopen's is and for the same reason (see libc/stdio.c): a stray read
 * cannot corrupt a future boot, a runaway write can.
 */
static int
l_fs_open(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	const char *mode = luaL_optstring(L, 2, "r");
	int write = (mode[0] == 'w' || mode[0] == 'a');

	if (write && !kernel_current_has_disk()) {
		lua_pushnil(L);
		lua_pushstring(L, "permission denied");
		return 2;
	}

	void *f = fs_open(path, write);

	if (!f) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot open %s", path);
		return 2;
	}

	struct fsfile *u = (struct fsfile *)lua_newuserdatauv(L,
	    sizeof *u, 0);

	u->f = f;
	luaL_setmetatable(L, FSFILE);
	return 1;
}

/* read(n) -> string. "" is end of file, matching src/dev.c's contract
 * rather than lua's nil, since espfs is the only caller and that is what
 * it has to return.
 */
static int
l_file_read(lua_State *L)
{
	void *f = openfile(L);
	lua_Integer n = luaL_checkinteger(L, 2);

	if (n < 0)
		return luaL_error(L, "negative read");
	if (n == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	luaL_Buffer b;
	char *p = luaL_buffinitsize(L, &b, (size_t)n);
	long got = fs_read(f, p, (long)n);

	if (got < 0)
		got = 0;
	luaL_pushresultsize(&b, (size_t)got);
	return 1;
}

static int
l_file_write(lua_State *L)
{
	void *f = openfile(L);
	size_t n;
	const char *s = luaL_checklstring(L, 2, &n);
	long put = fs_write(f, s, (long)n);

	if (put < 0) {
		lua_pushnil(L);
		lua_pushstring(L, "i/o error");
		return 2;
	}
	lua_pushinteger(L, put);
	return 1;
}

/* seek(pos) -> pos. absolute only: src/dev.c takes explicit offsets,
 * so nothing here has ever needed cur/end.
 */
static int
l_file_seek(lua_State *L)
{
	void *f = openfile(L);
	lua_Integer pos = luaL_checkinteger(L, 2);

	if (fs_seek(f, (long)pos, 0) != 0) {
		lua_pushnil(L);
		lua_pushstring(L, "cannot seek");
		return 2;
	}
	lua_pushinteger(L, fs_tell(f));
	return 1;
}

/* idempotent, so an explicit close followed by __gc is not an error */
static int
l_file_close(lua_State *L)
{
	struct fsfile *u = checkfile(L);

	if (u->f) {
		fs_flush(u->f);
		fs_close(u->f);
		u->f = NULL;
	}
	return 0;
}

static const luaL_Reg filelib[] = {
	{ "read", l_file_read },
	{ "write", l_file_write },
	{ "seek", l_file_seek },
	{ "close", l_file_close },
	{ NULL, NULL }
};

static const luaL_Reg fslib[] = {
	{ "readdir", l_fs_readdir },
	{ "stat", l_fs_stat },
	{ "open", l_fs_open },
	{ NULL, NULL }
};

int luaopen_los_fs(lua_State *L);

int
luaopen_los_fs(lua_State *L)
{
	luaL_newmetatable(L, FSFILE);
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");
	luaL_setfuncs(L, filelib, 0);
	lua_pushcfunction(L, l_file_close);
	lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, l_file_close);
	lua_setfield(L, -2, "__close");	/* so `local f <close> = ...` works */
	lua_pop(L, 1);

	luaL_newlib(L, fslib);
	return 1;
}
