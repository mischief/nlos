/* custom library set: everything except io, os, package
 * (no filesystem or process world yet)
 */

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

static const luaL_Reg loadedlibs[] = {
	{ LUA_GNAME, luaopen_base },
	{ LUA_COLIBNAME, luaopen_coroutine },
	{ LUA_TABLIBNAME, luaopen_table },
	{ LUA_STRLIBNAME, luaopen_string },
	{ LUA_MATHLIBNAME, luaopen_math },
	{ LUA_UTF8LIBNAME, luaopen_utf8 },
	{ LUA_DBLIBNAME, luaopen_debug },
	{ NULL, NULL }
};

LUALIB_API void
luaL_openlibs(lua_State *L)
{
	const luaL_Reg *lib;

	for (lib = loadedlibs; lib->func; lib++) {
		luaL_requiref(L, lib->name, lib->func, 1);
		lua_pop(L, 1);
	}
}
