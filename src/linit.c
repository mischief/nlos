/* custom library set: everything except os and package */

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* los is not here: the kernel registers it in package.preload per proc
 * (it needs the per-proc api), so chunks require("los") explicitly.
 */
static const luaL_Reg loadedlibs[] = {
	{ LUA_LOADLIBNAME, luaopen_package },
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
