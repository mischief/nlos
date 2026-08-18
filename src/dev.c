/* dev: the interface every filesystem backend implements.
 *
 * A backend is a Lua table of nine functions (attach, walk, stat, open,
 * create, read, write, readdir, clunk). This is the machinery around
 * them: path splitting, walking, chunked i/o, and the error convention.
 */

/* Backends park -- mnt waits for a 9P reply, fatsrv on the device -- so
 * every call into one uses lua_callk or lua_pcallk. A plain lua_call
 * forbids the yield, and it surfaces as an i/o error from whichever
 * backend swallowed it. Loop state therefore lives in stack slots, not
 * C locals: a continuation resumes with the Lua stack and nothing else.
 */

#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "kernel.h"
#include "buf.h"

/* the 9P errors, under the names lua code already tests against */
static const struct {
	const char *name;
	const char *msg;
} errors[] = {
	{ "Enonexist", "file does not exist" },
	{ "Eexist", "file already exists" },
	{ "Enotdir", "not a directory" },
	{ "Eisdir", "file is a directory" },
	{ "Eperm", "permission denied" },
	{ "Ebadarg", "bad arg in system call" },
	{ "Eio", "i/o error" },
	{ "Ebadusefd", "inappropriate use of fd" },
	{ "Enotimpl", "not implemented" },
	{ "Exdev", "cross-device link" },
	{ "Eloop", "cannot move a directory into itself" },
	{ "Ebadfid", "unknown fid" },
	{ "Ehungup", "hungup" },
	{ NULL, NULL }
};

/* what dev.check requires of a backend */
static const char *required[] = {
	"attach", "walk", "stat", "open", "create", "read", "write",
	"readdir", "clunk", NULL
};

/* dev.error(msg) -- raise with no position prefix, so that a caller
 * comparing the message against dev.Enonexist still matches.
 */
static int
l_error(lua_State *L)
{
	lua_settop(L, 1);
	return lua_error(L);
}

/* ---- protect ---- */

static int
protect_done(lua_State *L, int status)
{
	if (status != LUA_OK) {
		lua_pushboolean(L, 0);
		lua_insert(L, -2);
		return 2;
	}
	lua_pushboolean(L, 1);
	lua_insert(L, 1);
	return lua_gettop(L);
}

static int
protect_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)ctx;
	return protect_done(L, status);
}

/* dev.protect(fn, ...) -> ok, results... */
static int
l_protect(lua_State *L)
{
	int n = lua_gettop(L);

	luaL_checktype(L, 1, LUA_TFUNCTION);
	return protect_done(L, lua_pcallk(L, n - 1, LUA_MULTRET, 0, 0,
	    protect_k));
}

/* ---- closable ---- */

static int
doclose_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)L; (void)status; (void)ctx;
	return 0;
}

/* the __close installed by dev.closable; the backend is upvalue 1.
 * Clunk over a mount parks, so this yields like any other call.
 */
static int
l_doclose(lua_State *L)
{
	lua_getfield(L, lua_upvalueindex(1), "clunk");
	lua_pushvalue(L, 1);
	lua_callk(L, 1, 0, 0, doclose_k);
	return 0;
}

/* dev.closable(B, h) -> h, with a __close that clunks it. Whatever
 * metatable h had is carried over, minus its own __close.
 */
static int
l_closable(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 2);
	lua_newtable(L);			/* 3: the new metatable */

	if (lua_getmetatable(L, 2)) {		/* 4: the old one */
		lua_pushnil(L);
		while (lua_next(L, 4)) {	/* 5:k 6:v */
			if (lua_type(L, 5) == LUA_TSTRING &&
			    strcmp(lua_tostring(L, 5), "__close") == 0) {
				lua_pop(L, 1);
				continue;
			}
			lua_pushvalue(L, 5);	/* 5:k 6:v 7:k */
			lua_insert(L, 6);	/* 5:k 6:k 7:v */
			lua_settable(L, 3);
		}
		lua_pop(L, 1);
	}

	lua_pushvalue(L, 1);
	lua_pushcclosure(L, l_doclose, 1);
	lua_setfield(L, 3, "__close");
	lua_pushvalue(L, 3);
	lua_setmetatable(L, 2);
	lua_settop(L, 2);
	return 1;
}

/* ---- elements ---- */

/* push the path at idx split on '/', dropping "." and empty names */
static void
push_elements(lua_State *L, int idx)
{
	size_t len;
	const char *p;
	size_t i = 0;
	int n = 0;

	p = luaL_tolstring(L, idx, &len);	/* the copy keeps p alive */
	lua_newtable(L);
	while (i < len) {
		size_t start;

		while (i < len && p[i] == '/')
			i++;
		start = i;
		while (i < len && p[i] != '/')
			i++;
		if (i == start)
			continue;
		if (i - start == 1 && p[start] == '.')
			continue;
		lua_pushlstring(L, p + start, i - start);
		lua_rawseti(L, -2, ++n);
	}
	lua_remove(L, -2);			/* the tolstring copy */
}

/* dev.elements(path) -> { name, ... } */
static int
l_elements(lua_State *L)
{
	luaL_checkany(L, 1);
	push_elements(L, 1);
	return 1;
}

/* ---- walking ----
 *
 * Stack: 1 backend, 2 handle, 3 names, 4 the handle walked to so far.
 * ctx carries the index of the element in flight.
 */

static int walk_loop(lua_State *L, lua_Integer i);

/* raise "<why>: '<element>'", naming what could not be walked */
static int
walk_failed(lua_State *L, lua_Integer i)
{
	luaL_tolstring(L, -1, NULL);		/* why, as text */
	lua_rawgeti(L, 3, i);
	luaL_tolstring(L, -1, NULL);		/* and the element */
	lua_pushfstring(L, "%s: '%s'", lua_tostring(L, -3),
	    lua_tostring(L, -1));
	return lua_error(L);
}

static int
walk_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_Integer i = (lua_Integer)ctx;

	if (status != LUA_OK && status != LUA_YIELD)
		return walk_failed(L, i);
	return walk_loop(L, i + 1);
}

static int
walk_loop(lua_State *L, lua_Integer i)
{
	lua_Integer n = luaL_len(L, 3);

	while (i <= n) {
		int st;

		lua_getfield(L, 1, "walk");
		lua_insert(L, -2);		/* walk, h */
		lua_rawgeti(L, 3, i);		/* walk, h, elem */
		st = lua_pcallk(L, 2, 1, 0, (lua_KContext)i, walk_k);
		if (st != LUA_OK)
			return walk_failed(L, i);
		i++;
	}
	return 1;
}

/* dev.walkall(backend, h, names) -- one element at a time */
static int
l_walkall(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 3, LUA_TTABLE);
	lua_settop(L, 3);
	lua_pushvalue(L, 2);
	return walk_loop(L, 1);
}

static int
walkmany_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)L; (void)status; (void)ctx;
	return 1;
}

/* dev.walknames(backend, h, names)
 *
 * A backend that offers walkmany takes the whole list in one call,
 * which over a mount is one message rather than one per element.
 */
static int
l_walknames(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 3, LUA_TTABLE);
	lua_settop(L, 3);

	if (luaL_len(L, 3) == 0) {
		lua_pushvalue(L, 2);
		return 1;
	}
	if (lua_getfield(L, 1, "walkmany") != LUA_TNIL) {
		lua_pushvalue(L, 2);
		lua_pushvalue(L, 3);
		lua_callk(L, 2, 1, 0, walkmany_k);
		return 1;
	}
	lua_pop(L, 1);
	lua_pushvalue(L, 2);
	return walk_loop(L, 1);
}

/* dev.walkpath(backend, h, path) */
static int
l_walkpath(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 3);
	push_elements(L, 3);
	lua_replace(L, 3);
	return l_walknames(L);
}

/* ---- chunked reads and writes ---- */

/* convert a buf on the stack top to a string, in place */
static void
tostr(lua_State *L)
{
	if (!luabuf_isbuf(L, -1))
		return;
	lua_getfield(L, -1, "str");
	lua_insert(L, -2);
	lua_call(L, 1, 1);		/* buf:str() is C, and cannot park */
}

/* length of a string or buf at idx */
static size_t
datalen(lua_State *L, int idx)
{
	size_t len = 0;

	if (luabuf_isbuf(L, idx))
		luabuf_check(L, idx, &len);
	else
		lua_tolstring(L, idx, &len);
	return len;
}

/*
 * readloop stack: 1 iounit, 2 one, 3 off, 4 n, 5 raw, 6 the pieces,
 * 7 bytes so far, 8 how many pieces, 9 the size last asked for.
 */
static int read_loop(lua_State *L);

static int
read_done(lua_State *L)
{
	int parts = (int)lua_tointeger(L, 8);
	int raw = lua_toboolean(L, 5);
	luaL_Buffer b;
	int i;

	if (parts == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	if (parts == 1) {
		lua_rawgeti(L, 6, 1);
		if (!raw)
			tostr(L);
		return 1;
	}

	/* a luaL_Buffer rather than table.concat: the table library loads
	 * on first reference, and a proc reading a file need not pay for
	 * it. Built after the last call, so nothing yields under it.
	 */
	luaL_buffinit(L, &b);
	for (i = 1; i <= parts; i++) {
		lua_rawgeti(L, 6, i);
		tostr(L);
		luaL_addvalue(&b);
	}
	luaL_pushresult(&b);
	return 1;
}

/* take the piece on top; 1 when the read is over */
static int
read_take(lua_State *L)
{
	lua_Integer want = lua_tointeger(L, 9);
	size_t dlen;
	int parts;

	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return 1;
	}
	dlen = datalen(L, -1);
	if (dlen == 0) {
		lua_pop(L, 1);
		return 1;			/* end of file */
	}
	parts = (int)lua_tointeger(L, 8) + 1;
	lua_rawseti(L, 6, parts);
	lua_pushinteger(L, parts);
	lua_replace(L, 8);
	lua_pushinteger(L, lua_tointeger(L, 7) + (lua_Integer)dlen);
	lua_replace(L, 7);
	return (lua_Integer)dlen < want;
}

static int
read_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status; (void)ctx;
	if (read_take(L))
		return read_done(L);
	return read_loop(L);
}

static int
read_loop(lua_State *L)
{
	lua_Integer iounit = lua_tointeger(L, 1);
	lua_Integer off = lua_tointeger(L, 3);
	lua_Integer n = lua_tointeger(L, 4);

	for (;;) {
		lua_Integer got = lua_tointeger(L, 7);
		lua_Integer want, room;

		if (got >= n)
			return read_done(L);

		want = n - got;
		room = iounit - (off + got) % iounit;
		if (want > room)
			want = room;
		lua_pushinteger(L, want);
		lua_replace(L, 9);

		lua_pushvalue(L, 2);
		lua_pushinteger(L, off + got);
		lua_pushinteger(L, want);
		lua_callk(L, 2, 1, 0, read_k);
		if (read_take(L))
			return read_done(L);
	}
}

/* dev.readloop(iounit, one, off, n, raw) -> data
 *
 * Calls one(off, want) until n bytes arrive or it answers short. Every
 * request stops at an iounit boundary, so a backend never sees a read
 * straddling two of its messages.
 *
 * raw keeps a single buf as a buf; otherwise the result is a string.
 */
static int
l_readloop(lua_State *L)
{
	lua_Integer iounit = luaL_checkinteger(L, 1);

	luaL_checktype(L, 2, LUA_TFUNCTION);
	luaL_checkinteger(L, 3);
	luaL_checkinteger(L, 4);
	if (iounit <= 0)
		return luaL_error(L, "dev.readloop: iounit must be positive");

	lua_settop(L, 5);
	lua_newtable(L);			/* 6: the pieces */
	lua_pushinteger(L, 0);			/* 7: bytes so far */
	lua_pushinteger(L, 0);			/* 8: how many pieces */
	lua_pushinteger(L, 0);			/* 9: last size asked for */
	return read_loop(L);
}

/*
 * writeloop stack: 1 iounit, 2 one, 3 off, 4 data, 5 written so far,
 * 6 the size last offered.
 */
static int write_loop(lua_State *L);

/* take the count on top; 1 when the write is over */
static int
write_take(lua_State *L)
{
	lua_Integer want = lua_tointeger(L, 6);
	lua_Integer w = lua_isnumber(L, -1) ? lua_tointeger(L, -1) : 0;

	lua_pop(L, 1);
	if (w <= 0)
		return 1;
	lua_pushinteger(L, lua_tointeger(L, 5) + w);
	lua_replace(L, 5);
	return w < want;
}

static int
write_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status; (void)ctx;
	if (write_take(L)) {
		lua_pushvalue(L, 5);
		return 1;
	}
	return write_loop(L);
}

static int
write_loop(lua_State *L)
{
	lua_Integer iounit = lua_tointeger(L, 1);
	lua_Integer off = lua_tointeger(L, 3);
	int isbuf = luabuf_isbuf(L, 4);
	size_t dlen;
	lua_Integer n;

	if (isbuf)
		luabuf_check(L, 4, &dlen);
	else
		lua_tolstring(L, 4, &dlen);
	n = (lua_Integer)dlen;

	for (;;) {
		lua_Integer done = lua_tointeger(L, 5);
		lua_Integer want, room;

		if (done >= n) {
			lua_pushvalue(L, 5);
			return 1;
		}

		want = n - done;
		room = iounit - (off + done) % iounit;
		if (want > room)
			want = room;
		lua_pushinteger(L, want);
		lua_replace(L, 6);

		lua_pushvalue(L, 2);
		lua_pushinteger(L, off + done);
		if (isbuf) {
			luabuf_pushview(L, 4, (size_t)done, (size_t)want);
		} else {
			const char *s = lua_tostring(L, 4);

			lua_pushlstring(L, s + done, (size_t)want);
		}
		lua_callk(L, 2, 1, 0, write_k);
		if (write_take(L)) {
			lua_pushvalue(L, 5);
			return 1;
		}
	}
}

/* dev.writeloop(iounit, one, off, data) -> bytes written
 *
 * The mirror of readloop: one(off, chunk) per iounit-aligned piece,
 * stopping early on a short write. A buf is written as views of itself
 * rather than copied.
 */
static int
l_writeloop(lua_State *L)
{
	lua_Integer iounit = luaL_checkinteger(L, 1);

	luaL_checktype(L, 2, LUA_TFUNCTION);
	luaL_checkinteger(L, 3);
	if (iounit <= 0)
		return luaL_error(L, "dev.writeloop: iounit must be positive");
	if (!luabuf_isbuf(L, 4))
		luaL_checktype(L, 4, LUA_TSTRING);

	lua_settop(L, 4);
	lua_pushinteger(L, 0);			/* 5: written so far */
	lua_pushinteger(L, 0);			/* 6: last size offered */
	return write_loop(L);
}

/* dev.check(backend, name) -> backend, raising if a method is missing */
static int
l_check(lua_State *L)
{
	const char *name = luaL_optstring(L, 2, "backend");
	int i;

	if (lua_type(L, 1) != LUA_TTABLE)
		return luaL_error(L, "%s: not a table", name);
	for (i = 0; required[i]; i++) {
		int t = lua_getfield(L, 1, required[i]);

		lua_pop(L, 1);
		if (t != LUA_TFUNCTION)
			return luaL_error(L, "%s: missing %s()", name,
			    required[i]);
	}
	lua_settop(L, 1);
	return 1;
}

static const luaL_Reg devlib[] = {
	{ "error", l_error },
	{ "protect", l_protect },
	{ "closable", l_closable },
	{ "elements", l_elements },
	{ "walkall", l_walkall },
	{ "walknames", l_walknames },
	{ "walkpath", l_walkpath },
	{ "readloop", l_readloop },
	{ "writeloop", l_writeloop },
	{ "check", l_check },
	{ NULL, NULL }
};

int luaopen_dev(lua_State *L);

int
luaopen_dev(lua_State *L)
{
	lua_Integer iounit = 16384;
	int i;

	luaL_newlib(L, devlib);

	for (i = 0; errors[i].name; i++) {
		lua_pushstring(L, errors[i].msg);
		lua_setfield(L, -2, errors[i].name);
	}

	/* a read has to fit in one message, with room for its envelope */
	if (iounit > MAXMSG - 4096)
		iounit = MAXMSG - 4096;
	lua_pushinteger(L, iounit);
	lua_setfield(L, -2, "IOUNIT");

	return 1;
}
