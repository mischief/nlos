/* crypto.native for the host tests: a name, and nothing else.
 *
 * Lua's last searcher takes crypto.native to crypto.so and calls
 * luaopen_crypto_native. The guest preloads the same module under a
 * name of its own, so this keeps both testing one implementation.
 */

#include "lua.h"
#include "lauxlib.h"

int luaopen_ssh_crypto_native(lua_State *L);
int luaopen_crypto_native(lua_State *L);

int
luaopen_crypto_native(lua_State *L)
{
	return luaopen_ssh_crypto_native(L);
}
