/* custom library set: everything except os and package */

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

int luaopen_los(lua_State *L);

static const luaL_Reg loadedlibs[] = {
	{ "los", luaopen_los },
	{ LUA_IOLIBNAME, luaopen_io },
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
