/* custom library set: everything except os, and most of it lazy.
 * base/string/package load eagerly (below); coroutine/io/table/math/
 * utf8/debug are deferred until first reference via a metatable on
 * _G, so a small kernel-side task that never touches them never pays
 * for their function tables/metatables.
 */

#include <string.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* there's no top-level "los" module: los.sys/los.efi/los.thread and
 * (for exactly one task each) los.platform.* are registered directly
 * in package.preload per proc by kernel.c's proc_new, and chunks
 * require() each dotted path on its own -- require("los") itself was
 * never built, don't go looking for a los.lua stub.
 */
static const luaL_Reg eagerlibs[] = {
	{ LUA_GNAME, luaopen_base },
	{ LUA_STRLIBNAME, luaopen_string },
	{ LUA_LOADLIBNAME, luaopen_package },
	{ NULL, NULL }
};

static const struct { const char *name; lua_CFunction f; } lazylibs[] = {
	{ LUA_COLIBNAME, luaopen_coroutine },
	{ LUA_IOLIBNAME, luaopen_io },
	{ LUA_TABLIBNAME, luaopen_table },
	{ LUA_MATHLIBNAME, luaopen_math },
	{ LUA_UTF8LIBNAME, luaopen_utf8 },
	{ LUA_DBLIBNAME, luaopen_debug },
};

/* _G's __index: called only on a miss, so this never fires again for
 * a given name once loaded (luaL_requiref with glb=1 both registers
 * package.loaded[name] and does the equivalent of _G[name] = module,
 * a plain rawset since we install no __newindex).
 */
static int
lazylib_index(lua_State *L)
{
	const char *key = lua_tostring(L, 2);
	size_t i;

	if (key)
		for (i = 0; i < sizeof lazylibs / sizeof lazylibs[0]; i++)
			if (strcmp(key, lazylibs[i].name) == 0) {
				luaL_requiref(L, key, lazylibs[i].f, 1);
				return 1;
			}
	lua_pushnil(L);
	return 1;
}

LUALIB_API void
luaL_openlibs(lua_State *L)
{
	const luaL_Reg *lib;

	for (lib = eagerlibs; lib->func; lib++) {
		luaL_requiref(L, lib->name, lib->func, 1);
		lua_pop(L, 1);
	}

	/* string stays eager (not just "commonly used"): luaopen_string
	 * installs a metatable shared by every string value in the
	 * state, needed the first time ANY string is indexed/called as
	 * a method (e.g. "x":upper()), which can happen with no visible
	 * `string` reference to hang a lazy hook off of. base is eager
	 * too (print/pcall/tostring/error/...), basically everything
	 * assumes it's there and the win from deferring it is ~nil.
	 * package is eager because luaopen_package is what installs the
	 * global `require` function itself -- lazy-loading it would mean
	 * intercepting a miss on `require`, not on `package`, which is
	 * doable but its own footgun (require() is what every chunk uses
	 * to pull in los.sys/los.thread/etc in the first place, and the
	 * kernel's own preload registration in proc_new also expects
	 * package.preload to already exist) -- not worth the saved bytes.
	 */
	lua_pushglobaltable(L);
	lua_newtable(L);
	lua_pushcfunction(L, lazylib_index);
	lua_setfield(L, -2, "__index");
	lua_setmetatable(L, -2);
	lua_pop(L, 1);
}
