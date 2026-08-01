/* hostutil: the one first-party C module backing the Lua ports of
 * test/test_*.py. stock Lua has no socket module and no argv-array
 * process spawning at all -- this is "ours, not vendored" rather than
 * pulling in LuaSocket, the same call the project already makes for
 * every other place its own C floor has to stand in for something
 * Lua's stdlib doesn't reach.
 *
 * scope is deliberately narrow: exactly what test/test_9p.lua,
 * test_http.lua, test_mcp.lua and test_web.lua use. no listen/accept
 * (these are clients only), no HTTP (that's hand-rolled in Lua on top
 * of send/recv, in test/hosthttp.lua).
 *
 * this is a HOST tool, built native (see meson.build's native: true)
 * regardless of what -Dplatform/cross-file the freestanding kernel
 * build is using -- it runs on the machine driving the tests, never on
 * the guest.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

static int
l_connect_tcp(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_Integer port = luaL_checkinteger(L, 2);
	char portbuf[16];
	struct addrinfo hints, *res, *rp;
	int fd = -1;

	snprintf(portbuf, sizeof portbuf, "%lld", (long long)port);
	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	if (getaddrinfo(host, portbuf, &hints, &res) != 0) {
		lua_pushnil(L);
		lua_pushstring(L, "getaddrinfo failed");
		return 2;
	}
	for (rp = res; rp; rp = rp->ai_next) {
		fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
		if (fd < 0)
			continue;
		if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
			break;
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);
	if (fd < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int
l_connect_unix(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	struct sockaddr_un addr;
	int fd;

	if (strlen(path) >= sizeof addr.sun_path) {
		lua_pushnil(L);
		lua_pushstring(L, "path too long");
		return 2;
	}
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	strcpy(addr.sun_path, path);
	if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
		int e = errno;

		close(fd);
		lua_pushnil(L);
		lua_pushstring(L, strerror(e));
		return 2;
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int
l_send(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	size_t len;
	const char *data = luaL_checklstring(L, 2, &len);
	size_t sent = 0;

	while (sent < len) {
		ssize_t n = send(fd, data + sent, len - sent, MSG_NOSIGNAL);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			lua_pushnil(L);
			lua_pushstring(L, strerror(errno));
			return 2;
		}
		sent += (size_t)n;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* recv(fd, maxlen, timeout_secs) -> data ("" on clean eof), or
 * nil, "timeout" | nil, errmsg.
 */
static int
l_recv(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	lua_Integer maxlen = luaL_checkinteger(L, 2);
	lua_Number timeout = luaL_optnumber(L, 3, 0);
	char *buf;
	ssize_t n;

	if (timeout > 0) {
		fd_set rfds;
		struct timeval tv;

		FD_ZERO(&rfds);
		FD_SET(fd, &rfds);
		tv.tv_sec = (long)timeout;
		tv.tv_usec = (long)((timeout - tv.tv_sec) * 1000000);
		int r = select(fd + 1, &rfds, NULL, NULL, &tv);

		if (r == 0) {
			lua_pushnil(L);
			lua_pushstring(L, "timeout");
			return 2;
		}
		if (r < 0) {
			lua_pushnil(L);
			lua_pushstring(L, strerror(errno));
			return 2;
		}
	}

	buf = malloc((size_t)maxlen);
	if (!buf)
		return luaL_error(L, "out of memory");
	n = recv(fd, buf, (size_t)maxlen, 0);
	if (n < 0) {
		free(buf);
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushlstring(L, buf, (size_t)n);
	free(buf);
	return 1;
}

static int
l_close(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);

	close(fd);
	return 0;
}

/* bind 127.0.0.1:0, read back the port getsockname assigned, close --
 * same "reserve a free port" trick as the python original's
 * free_port(). the small race (something else grabs it before qemu's
 * hostfwd binds) is the same race the python version accepted too.
 */
static int
l_free_port(lua_State *L)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in addr;
	socklen_t alen = sizeof addr;

	if (fd < 0)
		return luaL_error(L, "socket: %s", strerror(errno));
	memset(&addr, 0, sizeof addr);
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = 0;
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
		int e = errno;

		close(fd);
		return luaL_error(L, "bind: %s", strerror(e));
	}
	if (getsockname(fd, (struct sockaddr *)&addr, &alen) != 0) {
		int e = errno;

		close(fd);
		return luaL_error(L, "getsockname: %s", strerror(e));
	}
	close(fd);
	lua_pushinteger(L, ntohs(addr.sin_port));
	return 1;
}

static int
l_getpid(lua_State *L)
{
	lua_pushinteger(L, getpid());
	return 1;
}

/* spawn({argv...}) -> pid. stdin inherited, stdout/stderr to
 * /dev/null -- matching subprocess.Popen(..., stdout=DEVNULL,
 * stderr=DEVNULL) in every test/test_*.py original. argv[1] is
 * looked up via PATH (execvp), same as Popen's own default.
 */
static int
l_spawn(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_Integer n = luaL_len(L, 1);
	char **argv = malloc((size_t)(n + 1) * sizeof *argv);

	if (!argv)
		return luaL_error(L, "out of memory");
	for (lua_Integer i = 1; i <= n; i++) {
		lua_geti(L, 1, i);
		argv[i - 1] = strdup(luaL_checkstring(L, -1));
		lua_pop(L, 1);
	}
	argv[n] = NULL;

	pid_t pid = fork();

	if (pid < 0) {
		free(argv);	/* leaks the strdup'd argv strings; fork() failing is fatal-ish */
		return luaL_error(L, "fork: %s", strerror(errno));
	}
	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);

		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		execvp(argv[0], argv);
		_exit(127);
	}
	for (lua_Integer i = 0; i < n; i++)
		free(argv[i]);
	free(argv);
	lua_pushinteger(L, pid);
	return 1;
}

static int
l_kill(lua_State *L)
{
	pid_t pid = (pid_t)luaL_checkinteger(L, 1);

	kill(pid, SIGKILL);
	return 0;
}

/* blocking wait -- for cleanup, after kill(). a no-op (not an error)
 * if the child was already reaped by poll() below; the Lua side is
 * expected to track that itself, but ECHILD here is swallowed either
 * way since "already gone" is exactly what we wanted.
 */
static int
l_wait(lua_State *L)
{
	pid_t pid = (pid_t)luaL_checkinteger(L, 1);
	int status;

	waitpid(pid, &status, 0);
	return 0;
}

/* non-blocking: nil if still running, else the exit code (reaping the
 * child) -- mirrors Python's subprocess.Popen.poll() exactly, so the
 * Lua call sites read the same as the originals.
 */
static int
l_poll(lua_State *L)
{
	pid_t pid = (pid_t)luaL_checkinteger(L, 1);
	int status;
	pid_t r = waitpid(pid, &status, WNOHANG);

	if (r == 0) {
		lua_pushnil(L);
		return 1;
	}
	if (WIFEXITED(status))
		lua_pushinteger(L, WEXITSTATUS(status));
	else
		lua_pushinteger(L, -1);
	return 1;
}

static const luaL_Reg hostutil[] = {
	{ "connect_tcp", l_connect_tcp },
	{ "connect_unix", l_connect_unix },
	{ "send", l_send },
	{ "recv", l_recv },
	{ "close", l_close },
	{ "free_port", l_free_port },
	{ "getpid", l_getpid },
	{ "spawn", l_spawn },
	{ "kill", l_kill },
	{ "wait", l_wait },
	{ "poll", l_poll },
	{ NULL, NULL }
};

int luaopen_hostutil(lua_State *L);

int
luaopen_hostutil(lua_State *L)
{
	luaL_newlib(L, hostutil);
	return 1;
}
