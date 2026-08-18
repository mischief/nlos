/* chan: the result of evaluating a name. Plan 9's Chan, deliberately.
 *
 * A Chan is (backend, handle, name) plus a position. The first two are
 * what lib/dev needs to do anything; the third is the absolute rooted
 * path it was reached by, so ".." can be evaluated lexically and an
 * ambiguous mount point resolved by asking which name was used.
 */

/* A table, not a userdata: ns and nsfs read c.B, c.path and c.h to
 * build a Chan over a handle they opened themselves.
 *
 * Backends park, so calls into one use lua_pcallk, and the position
 * moves in the continuation.
 */

#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "buf.h"

#define CHANMT		"chan"		/* the shared metatable, in the registry */
#define DEVKEY		"chan.dev"	/* the dev module, for walkpath */

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

/* push a fresh Chan over (B, path, h) */
static void
push_chan(lua_State *L, int B, int path, int h)
{
	lua_createtable(L, 0, 4);
	lua_pushvalue(L, B);
	lua_setfield(L, -2, "B");
	lua_pushvalue(L, h);
	lua_setfield(L, -2, "h");
	lua_pushvalue(L, path);
	lua_setfield(L, -2, "path");
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "pos");
	luaL_setmetatable(L, CHANMT);
}

/* chan.new(B, path, h) */
static int
l_new(lua_State *L)
{
	lua_settop(L, 3);
	push_chan(L, 1, 2, 3);
	return 1;
}

/* chan.borrowed(B, path, h) -- closing it does not clunk the handle,
 * because the handle belongs to whoever lent it.
 */
static int
l_borrowed(lua_State *L)
{
	lua_settop(L, 3);
	push_chan(L, 1, 2, 3);
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "borrow");
	return 1;
}

/* chan.is(x) */
static int
l_is(lua_State *L)
{
	int same = 0;

	if (lua_getmetatable(L, 1)) {
		luaL_getmetatable(L, CHANMT);
		same = lua_rawequal(L, -1, -2);
		lua_pop(L, 2);
	}
	lua_pushboolean(L, same);
	return 1;
}

/* ---- the calls that reach a backend ----
 *
 * Each pushes B.<method> and its arguments, then pcallk. The
 * continuation reports nil plus the error, or updates the Chan.
 */

/* push self.B[name] and self.h; self is at 1 */
static void
push_call(lua_State *L, const char *name)
{
	lua_getfield(L, 1, "B");
	lua_getfield(L, -1, name);
	lua_remove(L, -2);			/* the backend table */
	lua_getfield(L, 1, "h");
}

/* a backend call that answers the value it returned, unchanged */
static int
plain_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)ctx;
	if (status != LUA_OK && status != LUA_YIELD) {
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	return 1;
}

/* Chan:stat() */
static int
l_stat(lua_State *L)
{
	lua_settop(L, 1);
	push_call(L, "stat");
	return plain_k(L, lua_pcallk(L, 1, 1, 0, 0, plain_k), 0);
}

/* Chan:readdir() */
static int
l_readdir(lua_State *L)
{
	lua_settop(L, 1);
	push_call(L, "readdir");
	return plain_k(L, lua_pcallk(L, 1, 1, 0, 0, plain_k), 0);
}

/* advance self.pos by the length of the value on top, then answer it */
static int
read_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_Integer pos;

	(void)ctx;
	if (status != LUA_OK && status != LUA_YIELD) {
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	lua_getfield(L, 1, "pos");
	pos = lua_tointeger(L, -1);
	lua_pop(L, 1);
	lua_pushinteger(L, pos + (lua_Integer)datalen(L, -1));
	lua_setfield(L, 1, "pos");
	return 1;
}

/* Chan:read(n) -- n bytes from the position, which then advances */
static int
l_read(lua_State *L)
{
	lua_Integer n;

	if (lua_isnoneornil(L, 2)) {
		n = 4096;
	} else if (lua_type(L, 2) != LUA_TNUMBER) {
		const char *tn = luaL_typename(L, 2);

		/* luaL_tolstring pushes, so the text is made before the
		 * nil that has to sit under it.
		 */
		luaL_tolstring(L, 2, NULL);
		lua_pushnil(L);
		lua_insert(L, -2);
		lua_pushfstring(L, "read: count must be a number, not %s (%s)",
		    tn, lua_tostring(L, -1));
		lua_remove(L, -2);
		return 2;
	} else {
		lua_Number f = lua_tonumber(L, 2);

		n = (lua_Integer)f;		/* toward zero, as floor does
						 * for the counts a caller
						 * passes */
	}

	lua_settop(L, 1);
	push_call(L, "read");
	lua_getfield(L, 1, "pos");
	lua_pushinteger(L, n);
	return read_k(L, lua_pcallk(L, 3, 1, 0, 0, read_k), 0);
}

/* the count written is what the position advances by */
static int
write_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_Integer pos;

	(void)ctx;
	if (status != LUA_OK && status != LUA_YIELD) {
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	lua_getfield(L, 1, "pos");
	pos = lua_tointeger(L, -1);
	lua_pop(L, 1);
	lua_pushinteger(L, pos + lua_tointeger(L, -1));
	lua_setfield(L, 1, "pos");
	return 1;
}

/* Chan:write(data) */
static int
l_write(lua_State *L)
{
	lua_settop(L, 2);
	push_call(L, "write");
	lua_getfield(L, 1, "pos");
	lua_pushvalue(L, 2);
	return write_k(L, lua_pcallk(L, 3, 1, 0, 0, write_k), 0);
}

/* ---- walking ---- */

/* join the names with '/' and push the result */
static void
push_joined(lua_State *L, int names)
{
	luaL_Buffer b;
	lua_Integer i, n = luaL_len(L, names);

	luaL_buffinit(L, &b);
	for (i = 1; i <= n; i++) {
		if (i > 1)
			luaL_addchar(&b, '/');
		lua_rawgeti(L, names, i);
		luaL_addvalue(&b);
	}
	luaL_pushresult(&b);
}

/* stack: 1 self, 2 names, 3 the joined path; the new handle is on top */
static int
walk_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status; (void)ctx;

	/* the child's name is the parent's, with the walk appended; a
	 * root of "/" contributes nothing, or the name gains "//".
	 */
	lua_getfield(L, 1, "path");
	{
		const char *pp = lua_tostring(L, -1);

	if (pp != NULL && strcmp(pp, "/") == 0) {
		lua_pop(L, 1);
		lua_pushliteral(L, "");
	}
	}
	lua_pushliteral(L, "/");
	lua_pushvalue(L, 3);
	lua_concat(L, 3);			/* 4: handle, 5: path */
	lua_insert(L, -2);			/* path, handle */

	lua_getfield(L, 1, "B");
	lua_insert(L, -3);			/* B, path, handle */
	push_chan(L, lua_gettop(L) - 2, lua_gettop(L) - 1, lua_gettop(L));
	return 1;
}

/* Chan:walk(names) -> a Chan for the name walked to */
static int
l_walk(lua_State *L)
{
	lua_settop(L, 2);
	luaL_checktype(L, 2, LUA_TTABLE);

	if (luaL_len(L, 2) == 0) {
		lua_pushvalue(L, 1);
		return 1;
	}
	push_joined(L, 2);			/* 3: the path walked */

	lua_getfield(L, LUA_REGISTRYINDEX, DEVKEY);
	lua_getfield(L, -1, "walkpath");
	lua_remove(L, -2);
	lua_getfield(L, 1, "B");
	lua_getfield(L, 1, "h");
	lua_pushvalue(L, 3);
	lua_callk(L, 3, 1, 0, walk_k);
	return walk_k(L, LUA_OK, 0);
}

/* ---- seek ---- */

static int
seekend_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_Integer off = (lua_Integer)ctx;

	(void)status;
	if (lua_isnil(L, -2)) {			/* stat failed: nil, why */
		return 2;
	}
	lua_getfield(L, -2, "size");
	lua_pushinteger(L, lua_tointeger(L, -1) + off);
	lua_setfield(L, 1, "pos");
	lua_getfield(L, 1, "pos");
	return 1;
}

/* Chan:seek(whence, off) -> the new position */
static int
l_seek(lua_State *L)
{
	const char *whence = lua_isnoneornil(L, 2) ? "set" :
	    lua_tostring(L, 2);
	lua_Integer off = (lua_Integer)luaL_optinteger(L, 3, 0);

	lua_settop(L, 3);
	if (whence == NULL) {
		lua_getfield(L, LUA_REGISTRYINDEX, DEVKEY);
		lua_getfield(L, -1, "Ebadarg");
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	if (strcmp(whence, "set") == 0) {
		lua_pushinteger(L, off);
		lua_setfield(L, 1, "pos");
	} else if (strcmp(whence, "cur") == 0) {
		lua_getfield(L, 1, "pos");
		lua_pushinteger(L, lua_tointeger(L, -1) + off);
		lua_setfield(L, 1, "pos");
		lua_pop(L, 1);
	} else if (strcmp(whence, "end") == 0) {
		lua_getfield(L, 1, "stat");
		lua_pushvalue(L, 1);
		lua_callk(L, 1, 2, (lua_KContext)off, seekend_k);
		return seekend_k(L, LUA_OK, (lua_KContext)off);
	} else {
		lua_getfield(L, LUA_REGISTRYINDEX, DEVKEY);
		lua_getfield(L, -1, "Ebadarg");
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	lua_getfield(L, 1, "pos");
	return 1;
}

/* ---- close ---- */

static int
close_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status; (void)ctx;
	lua_pushnil(L);
	lua_setfield(L, 1, "h");
	return 0;
}

/* Chan:close() -- clunk the handle unless it was borrowed */
static int
l_close(lua_State *L)
{
	lua_settop(L, 1);
	lua_getfield(L, 1, "h");
	lua_getfield(L, 1, "borrow");
	if (lua_isnil(L, -2) || lua_toboolean(L, -1)) {
		lua_pop(L, 2);
		lua_pushnil(L);
		lua_setfield(L, 1, "h");
		return 0;
	}
	lua_pop(L, 2);

	push_call(L, "clunk");
	lua_pcallk(L, 1, 0, 0, 0, close_k);
	return close_k(L, LUA_OK, 0);
}

static const luaL_Reg methods[] = {
	{ "walk", l_walk },
	{ "read", l_read },
	{ "write", l_write },
	{ "seek", l_seek },
	{ "stat", l_stat },
	{ "readdir", l_readdir },
	{ "close", l_close },
	{ NULL, NULL }
};

static const luaL_Reg chanlib[] = {
	{ "new", l_new },
	{ "borrowed", l_borrowed },
	{ "is", l_is },
	{ NULL, NULL }
};

int luaopen_chan(lua_State *L);

int
luaopen_chan(lua_State *L)
{
	/* dev, kept in the registry: walk goes through dev.walkpath so a
	 * backend offering walkmany still gets one message per walk.
	 */
	lua_getglobal(L, "require");
	lua_pushliteral(L, "dev");
	lua_call(L, 1, 1);
	lua_setfield(L, LUA_REGISTRYINDEX, DEVKEY);

	luaL_newmetatable(L, CHANMT);
	luaL_newlib(L, methods);
	lua_pushvalue(L, -1);
	lua_setfield(L, -3, "__index");		/* mt.__index = methods */
	lua_getfield(L, -1, "close");
	lua_setfield(L, -3, "__close");		/* a Chan is to-be-closed */

	luaL_newlib(L, chanlib);
	lua_insert(L, -3);			/* chan, methods, mt */
	lua_pop(L, 1);				/* chan, methods */

	lua_setfield(L, -2, "methods");
	return 1;
}
