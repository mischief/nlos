/* los.platform.ws: the browser's websockets, and the whole of what this
 * machine has of the network. Framed rather than streamed -- a message
 * arrives whole -- so lib/websocket.lua is not in the path: there is no
 * socket under this to build framing on.
 */

#include <stddef.h>
#include <string.h>

#include "host.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"
#include "wasm.h"

/* the largest message taken from a peer, matching lib/websocket.lua's
 * MAXMSG: a relay may send a very long event, and a machine this size
 * would rather drop it than run out of memory.
 */
#define WS_MAXMSG (128 * 1024)

int
platform_have_ws(void)
{
	return 1;
}

/* ws.open(url) -> id, or nil and why. The url is the host's to parse
 * and the host's to refuse: a page may only reach what its own origin
 * policy allows, and that is not this machine's rule to enforce.
 */
static int
ws_open(lua_State *L)
{
	size_t n;
	const char *url = luaL_checklstring(L, 1, &n);
	int id = host_ws_open(url, n);

	if (id < 0) {
		lua_pushnil(L);
		lua_pushstring(L, "the host would not open it");
		return 2;
	}
	lua_pushinteger(L, id);
	return 1;
}

/* ws.state(id) -> "connecting", "open" or "closed". A caller polls this
 * rather than blocking: opening one is a round trip to somewhere.
 */
static int
ws_state(lua_State *L)
{
	static const char *const names[] = { "connecting", "open", "closed" };
	int s = host_ws_state((int)luaL_checkinteger(L, 1));

	lua_pushstring(L, s >= 0 && s <= 2 ? names[s] : "closed");
	return 1;
}

static int
ws_send(lua_State *L)
{
	int id = (int)luaL_checkinteger(L, 1);
	size_t n;
	const char *p = luaL_checklstring(L, 2, &n);

	lua_pushboolean(L, host_ws_send(id, p, n));
	return 1;
}

/* ws.recv(id) -> message, or nil with "again" while none is waiting and
 * "closed" once the peer has gone. Never blocks: the task above parks
 * on its own port instead, so one slow relay cannot stop the rest.
 */
static int
ws_recv(lua_State *L)
{
	int id = (int)luaL_checkinteger(L, 1);
	luaL_Buffer b;
	char *p = luaL_buffinitsize(L, &b, WS_MAXMSG);
	int n = host_ws_recv(id, p, WS_MAXMSG);

	if (n < 0) {
		luaL_pushresultsize(&b, 0);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, n == -2 ? "closed" : "again");
		return 2;
	}
	luaL_pushresultsize(&b, (size_t)n);
	return 1;
}

static int
ws_close(lua_State *L)
{
	host_ws_close((int)luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg wslib[] = {
	{ "open", ws_open },
	{ "state", ws_state },
	{ "send", ws_send },
	{ "recv", ws_recv },
	{ "close", ws_close },
	{ NULL, NULL }
};

int luaopen_los_platform_ws(lua_State *L);

int
luaopen_los_platform_ws(lua_State *L)
{
	luaL_newlib(L, wslib);
	return 1;
}
