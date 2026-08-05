/* hostutil: the one first-party C module backing the Lua ports of
 * test/test_*.py. stock Lua has no socket module and no argv-array
 * process spawning at all -- this is "ours, not vendored" rather than
 * pulling in LuaSocket, the same call the project already makes for
 * every other place its own C floor has to stand in for something
 * Lua's stdlib doesn't reach.
 *
 * scope is deliberately narrow: what test/test_9p.lua, test_http.lua,
 * test_mcp.lua and test_web.lua use as clients, plus listen/accept for
 * test/hostserver.lua, which is the other direction -- a guest dialling
 * OUT needs something on the host to dial to. No HTTP (that's
 * hand-rolled in Lua on top of send/recv, in test/hosthttp.lua).
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
#include <sys/ioctl.h>
#include <termios.h>
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

/* bind 127.0.0.1:0, listen, and report both the fd and the port the
 * kernel picked. Loopback only and on purpose: everything this serves
 * is reached by a guest through qemu's user networking, which proxies
 * connections to 10.0.2.2 onto the host's loopback, so there is no
 * reason for it to be reachable from anywhere else.
 *
 * Asking for port 0 and reading back what was assigned avoids the race
 * in picking a free port and then binding it, which l_free_port below
 * still has because its caller (hostfwd) needs a number before qemu
 * exists.
 */
static int
l_listen_tcp(lua_State *L)
{
	lua_Integer backlog = luaL_optinteger(L, 1, 8);
	struct sockaddr_in addr;
	socklen_t len = sizeof addr;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;

	if (fd < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

	memset(&addr, 0, sizeof addr);
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = 0;

	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 ||
	    listen(fd, (int)backlog) != 0 ||
	    getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
		int e = errno;

		close(fd);
		lua_pushnil(L);
		lua_pushstring(L, strerror(e));
		return 2;
	}
	lua_pushinteger(L, fd);
	lua_pushinteger(L, ntohs(addr.sin_port));
	return 2;
}

/* accept with a timeout, so a caller driving a guest can give up rather
 * than block forever on a guest that never got as far as dialling.
 * Returns nil plus "timeout" in that case, which is a different answer
 * from nil plus an error and is worth telling apart in a test.
 */
static int
l_accept(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	double timeout = luaL_optnumber(L, 2, 10.0);
	struct timeval tv;
	fd_set r;
	int n, c;

	FD_ZERO(&r);
	FD_SET(fd, &r);
	tv.tv_sec = (time_t)timeout;
	tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);

	n = select(fd + 1, &r, NULL, NULL, &tv);
	if (n == 0) {
		lua_pushnil(L);
		lua_pushstring(L, "timeout");
		return 2;
	}
	if (n < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}

	c = accept(fd, NULL, NULL);
	if (c < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushinteger(L, c);
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

/* spawn({argv...} [, {stdin=fd, stdout=fd, stderr=fd}]) -> pid.
 *
 * Without the second argument: stdin inherited, stdout/stderr to
 * /dev/null -- matching subprocess.Popen(..., stdout=DEVNULL,
 * stderr=DEVNULL) in every test/test_*.py original. argv[1] is
 * looked up via PATH (execvp), same as Popen's own default.
 *
 * With it, the named descriptors are wired instead. That exists for
 * serial(): a file-transfer program has to be handed the descriptor
 * already open on the line rather than opening the port itself, which
 * would reset the board.
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
		static const char *const names[] = {
			"stdin", "stdout", "stderr"
		};
		int wired[3] = { -1, -1, -1 };

		if (lua_istable(L, 2)) {
			for (int i = 0; i < 3; i++) {
				if (lua_getfield(L, 2, names[i]) ==
				    LUA_TNUMBER)
					wired[i] = (int)lua_tointeger(L, -1);
				lua_pop(L, 1);
			}
		}
		for (int i = 0; i < 3; i++)
			if (wired[i] >= 0)
				dup2(wired[i], i);

		/* only the streams left unwired are discarded, so asking
		 * for stderr and nothing else still gets the diagnostics.
		 */
		if (wired[1] < 0 || wired[2] < 0) {
			int devnull = open("/dev/null", O_WRONLY);

			if (devnull >= 0) {
				if (wired[1] < 0)
					dup2(devnull, STDOUT_FILENO);
				if (wired[2] < 0)
					dup2(devnull, STDERR_FILENO);
				close(devnull);
			}
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

/* the close method lua's io library calls on our file handles. */
static int
l_closef(lua_State *L)
{
	luaL_Stream *s = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
	int rc = s->f ? fclose(s->f) : 0;

	s->f = 0;
	return luaL_fileresult(L, rc == 0, NULL);
}

/* serial(path [, baud]) -> file
 *
 * A tty opened as a lua file, so read/write/lines/setvbuf are the ones
 * already in io. The alternative has been driving a board through
 * socat, which resets it: on an esp32 with native USB-Serial-JTAG the
 * ROM reads DTR/RTS as the reset strap, and socat asserts them when it
 * attaches. Measured as rst:0x15 (USB_UART_CHIP_RESET) in the middle
 * of a session, which loses whatever was typed before it -- and, worse,
 * looks like a protocol failure rather than a reboot. hupcl=0 does not
 * help; that governs the drop at close, not the raise at open.
 *
 * Nothing about a tty forces this: picocom does not reset the board,
 * and neither does a plain open of the same port -- both measured.
 * Whatever socat does to the modem lines it does on top of opening,
 * so simply not doing it is enough; no flag here is load-bearing.
 *
 * Holding the descriptor open for the whole session then lets a
 * receiver like lrz be handed the very line the commands went out on.
 *
 * O_NONBLOCK on the open is the ordinary tty courtesy -- do not wait
 * for carrier -- and is cleared straight after, because the only reads
 * here go through stdio, which wants a blocking fd and gets its
 * timeout from VMIN/VTIME instead.
 *
 * Raw, because this carries binary: no line discipline, no echo, no
 * CR/LF translation. A ZMODEM subpacket containing 0x0a survives only
 * if nothing on the host is helping.
 */
static int
l_serial(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	lua_Integer baud = luaL_optinteger(L, 2, 115200);
	speed_t sp;
	struct termios t;
	luaL_Stream *s;
	int fd;

	switch (baud) {
	case 9600: sp = B9600; break;
	case 19200: sp = B19200; break;
	case 38400: sp = B38400; break;
	case 57600: sp = B57600; break;
	case 115200: sp = B115200; break;
	case 230400: sp = B230400; break;
	case 460800: sp = B460800; break;
	case 921600: sp = B921600; break;
	default:
		return luaL_error(L, "unsupported baud %d", (int)baud);
	}

	/* O_NOCTTY: a tty opened by a test driver must not become the
	 * driver's controlling terminal, or a hangup on the line kills it.
	 */
	fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
	if (tcgetattr(fd, &t) == 0) {
		cfmakeraw(&t);
		cfsetispeed(&t, sp);
		cfsetospeed(&t, sp);
		/* CLOCAL: ignore modem control, so a line with no carrier
		 * still reads. HUPCL off so closing does not drop DTR --
		 * that drop is a reset on the boards this drives.
		 */
		t.c_cflag |= CLOCAL | CREAD;
		t.c_cflag &= ~(unsigned)HUPCL;
		/* block until at least one byte rather than time out.
		 * A VTIME expiry is a zero-length read, and stdio cannot
		 * tell that from end of file -- it latches EOF and every
		 * later read on the handle returns nil, so one quiet
		 * second would retire the port for good. Lua's io has no
		 * clearerr to undo it. Callers that need a deadline own
		 * one already (the process running them).
		 */
		t.c_cc[VMIN] = 1;
		t.c_cc[VTIME] = 0;
		tcsetattr(fd, TCSANOW, &t);
	}

	/* raise DTR and RTS together.
	 *
	 * Not cosmetic: an esp32's USB-Serial-JTAG treats DTR as "a host
	 * is attached" and stays silent without it, so a port opened with
	 * the line low looks like a dead board. What resets the chip is
	 * the ORDER -- the strap is a transition sequence, which is why
	 * esptool toggles them one at a time and why socat rebooted the
	 * board -- so setting both in one ioctl attaches without one.
	 */
	{
		int bits = TIOCM_DTR | TIOCM_RTS;

		ioctl(fd, TIOCMBIS, &bits);
	}

	s = (luaL_Stream *)lua_newuserdatauv(L, sizeof *s, 0);
	s->closef = 0;
	luaL_setmetatable(L, LUA_FILEHANDLE);
	s->f = fdopen(fd, "r+");
	if (!s->f) {
		close(fd);
		lua_pushnil(L);
		lua_pushstring(L, "fdopen");
		return 2;
	}
	/* unbuffered: a prompt that arrives without a newline must be
	 * readable, and a command must go out when written.
	 *
	 * Callers must still f:flush() before reading after a write. The
	 * stream is read/write, and C requires the direction change be
	 * separated by a flush or a seek whatever the buffering -- skip it
	 * and the read blocks forever on a line that is working fine.
	 */
	setvbuf(s->f, NULL, _IONBF, 0);
	s->closef = l_closef;
	return 1;
}

/* readable(fd [, timeout]) -> true | false
 *
 * Whether a read would return without blocking. serial() hands back a
 * blocking line on purpose (see there: a timeout is a zero-length read
 * and stdio cannot tell that from eof), which leaves a caller no way to
 * ask for something a guest might never say -- and the report explaining
 * why a transfer failed is exactly that. select answers it without
 * touching the stream.
 */
static int
l_readable(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	double timeout = luaL_optnumber(L, 2, 0.0);
	struct timeval tv;
	fd_set r;
	int n;

	FD_ZERO(&r);
	FD_SET(fd, &r);
	tv.tv_sec = (time_t)timeout;
	tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);

	n = select(fd + 1, &r, NULL, NULL, &tv);
	lua_pushboolean(L, n > 0);
	return 1;
}

/* fileno(file) -> fd, so a receiver spawned with spawn() can be given
 * this very descriptor rather than opening the port a second time.
 */
static int
l_fileno(lua_State *L)
{
	luaL_Stream *s = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);

	lua_pushinteger(L, fileno(s->f));
	return 1;
}

static const luaL_Reg hostutil[] = {
	{ "serial", l_serial },
	{ "fileno", l_fileno },
	{ "readable", l_readable },
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
	{ "listen_tcp", l_listen_tcp },
	{ "accept", l_accept },
	{ NULL, NULL }
};

int luaopen_hostutil(lua_State *L);

int
luaopen_hostutil(lua_State *L)
{
	luaL_newlib(L, hostutil);
	return 1;
}
