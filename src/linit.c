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

#include "kernel.h"

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
 *
 * Because it is only reached on a miss, it is also the one place that
 * knows a global was never bound -- so it raises rather than handing
 * back nil. `prit("x")` is a typo, and the error naming `prit` at the
 * line that read it beats "attempt to call a nil value" and beats a
 * silent nil propagating somewhere else entirely. It costs nothing on
 * the hit path: a bound global never reaches a metamethod at all.
 *
 * The escape, for a name that is legitimately maybe-absent, is
 * rawget(_G, "name") -- metamethods do not run for a raw access, so it
 * still answers nil. Assignment is deliberately NOT guarded: there is
 * no __newindex here, so `x = 1` still binds a fresh global. Read
 * checking already catches the mistake that matters, since
 * `total = total + 1` on an undeclared `total` reads it first.
 */
static int
lazylib_index(lua_State *L)
{
	/* before lua_tostring, which converts a number key to a string in
	 * place -- ask afterwards and every numeric key looks like a
	 * string.
	 */
	int isname = lua_type(L, 2) == LUA_TSTRING;
	const char *key = lua_tostring(L, 2);
	size_t i;

	if (key)
		for (i = 0; i < sizeof lazylibs / sizeof lazylibs[0]; i++)
			if (strcmp(key, lazylibs[i].name) == 0) {
				luaL_requiref(L, key, lazylibs[i].f, 1);
				/* RE-STRIP. luaL_requiref re-runs the opener
				 * whenever package.loaded[name] is falsy, and
				 * an unprivileged proc can do
				 *
				 *	package.loaded.io = nil
				 *	_G.io = nil
				 *	io.open("/init.lua")
				 *
				 * to land here and be handed a fresh, whole io
				 * -- which read a real ESP file straight out
				 * of a proc whose namespace held one in-memory
				 * tree. the strip in proc_new is not enough on
				 * its own because this path can rebuild what
				 * it removed.
				 */
				if (strcmp(key, LUA_IOLIBNAME) == 0 &&
				    !kernel_current_is_boot())
					kernel_strip_io(L);
				/* same trick, same answer: clearing
				 * package.loaded.debug and touching debug
				 * again lands here and would otherwise hand
				 * back a whole one, sethook included.
				 */
				if (strcmp(key, LUA_DBLIBNAME) == 0 &&
				    !kernel_current_is_boot())
					kernel_strip_debug(L);
				return 1;
			}
	/* only a string key is a variable name. _G[1] and _G[t] are table
	 * accesses that happen to land on the globals table, and no
	 * compiler emitted them for an identifier, so they keep the old
	 * nil rather than being called undeclared.
	 */
	if (!isname) {
		lua_pushnil(L);
		return 1;
	}
	return luaL_error(L, "undefined global '%s'", key);
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
