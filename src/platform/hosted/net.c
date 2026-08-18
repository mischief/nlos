/* los.platform.tcp: connections from the host's sockets. A token
 * machine, because the task above it is written against one: dial,
 * accept, send and recv each start an operation and hand back a token,
 * which the task polls when the kernel wakes it. The sockets are
 * non-blocking, so a poll either finishes or says "not yet".
 */

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "hosted.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"

/* the most one recv asks the host for. A client naming a larger maxlen
 * gets a short read, which every reader here already handles.
 */
#define NET_MAXIO 65536

/* a connection, as the task holds it: light userdata is not enough --
 * the fd has to be closeable exactly once, and a lua object with a
 * metatable is what gives the collector a say.
 */
#define CONNMT "los.tcp.conn"

struct conn {
	int fd;
	int listening;
	int closed;
};

enum { OP_DIAL = 1, OP_ACCEPT, OP_SEND, OP_RECV };

/* an outstanding operation. Tokens are lua objects too, so an abandoned
 * one is collected rather than leaked, and the poll set below holds
 * only what is genuinely still wanted.
 */
#define TOKENMT "los.tcp.token"

struct token {
	int kind;
	struct conn *c;
	int done;

	/* send: what is left to write, and how much went. recv: the most
	 * to ask for. Both are small and fixed, so the token owns them.
	 */
	char *buf;
	size_t len, off;
	size_t want;
};

/* every live token, so platform_net_ready can ask the host about all of
 * them at once. Registered at creation and dropped when the token
 * completes or is collected -- an operation nobody is waiting for must
 * leave, or its socket keeps the machine awake.
 */
#define MAXTOKENS 256

static struct token *live[MAXTOKENS];
static int nlive;

static void
live_add(struct token *t)
{
	if (nlive < MAXTOKENS)
		live[nlive++] = t;
}

static void
live_del(struct token *t)
{
	for (int i = 0; i < nlive; i++)
		if (live[i] == t) {
			live[i] = live[--nlive];
			return;
		}
}

/* which way a token's socket has to move before it can make progress */
static short
token_events(const struct token *t)
{
	switch (t->kind) {
	case OP_DIAL:
	case OP_SEND:
		return POLLOUT;
	case OP_ACCEPT:
	case OP_RECV:
		return POLLIN;
	}
	return 0;
}

int
platform_have_net(void)
{
	return 1;
}

int
platform_net_ready(void)
{
	struct pollfd pfd[MAXTOKENS];
	int n = 0;

	for (int i = 0; i < nlive; i++) {
		if (live[i]->done || !live[i]->c || live[i]->c->closed)
			continue;
		pfd[n].fd = live[i]->c->fd;
		pfd[n].events = token_events(live[i]);
		pfd[n].revents = 0;
		n++;
	}
	if (n == 0)
		return 0;
	return poll(pfd, (nfds_t)n, 0) > 0;
}

int
net_pollfds(struct pollfd *out, int max)
{
	int n = 0;

	for (int i = 0; i < nlive && n < max; i++) {
		if (live[i]->done || !live[i]->c || live[i]->c->closed)
			continue;
		out[n].fd = live[i]->c->fd;
		out[n].events = token_events(live[i]);
		out[n].revents = 0;
		n++;
	}
	return n;
}

static int
nonblock(int fd)
{
	int fl = fcntl(fd, F_GETFL, 0);

	return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static struct conn *
newconn(lua_State *L, int fd, int listening)
{
	struct conn *c = lua_newuserdatauv(L, sizeof *c, 0);

	c->fd = fd;
	c->listening = listening;
	c->closed = 0;
	luaL_setmetatable(L, CONNMT);
	return c;
}

static struct conn *
checkconn(lua_State *L, int idx)
{
	struct conn *c = luaL_checkudata(L, idx, CONNMT);

	if (c->closed)
		luaL_error(L, "the connection is closed");
	return c;
}

static struct token *
newtoken(lua_State *L, int kind, struct conn *c)
{
	struct token *t = lua_newuserdatauv(L, sizeof *t, 1);

	memset(t, 0, sizeof *t);
	t->kind = kind;
	t->c = c;
	luaL_setmetatable(L, TOKENMT);

	/* the connection, kept in the token's uservalue: the task may
	 * drop its own reference while an operation is outstanding, and
	 * the fd must outlive that.
	 */
	lua_pushvalue(L, -2);
	lua_setiuservalue(L, -2, 1);
	live_add(t);
	return t;
}

static void
finish(struct token *t)
{
	t->done = 1;
	live_del(t);
	free(t->buf);
	t->buf = NULL;
}

static int
conn_gc(lua_State *L)
{
	struct conn *c = luaL_checkudata(L, 1, CONNMT);

	if (!c->closed && c->fd >= 0)
		close(c->fd);
	c->closed = 1;
	return 0;
}

static int
token_gc(lua_State *L)
{
	struct token *t = luaL_checkudata(L, 1, TOKENMT);

	if (!t->done)
		finish(t);
	free(t->buf);
	t->buf = NULL;
	return 0;
}

/* ---- listen and dial ---- */

static void
addr_of(lua_State *L, int base, struct sockaddr_in *sa, int port)
{
	unsigned char q[4];

	for (int i = 0; i < 4; i++)
		q[i] = (unsigned char)luaL_checkinteger(L, base + i);
	memset(sa, 0, sizeof *sa);
	sa->sin_family = AF_INET;
	sa->sin_port = htons((unsigned short)port);
	memcpy(&sa->sin_addr, q, 4);
}

static int
l_listen(lua_State *L)
{
	int port = (int)luaL_checkinteger(L, 1);
	struct sockaddr_in sa;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;

	if (fd < 0)
		return 0;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET;
	sa.sin_port = htons((unsigned short)port);
	sa.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 ||
	    listen(fd, 16) != 0 || nonblock(fd) != 0) {
		close(fd);
		return 0;
	}
	newconn(L, fd, 1);
	return 1;
}

static int
l_dial_start(lua_State *L)
{
	struct sockaddr_in sa;
	int port = (int)luaL_checkinteger(L, 5);
	int fd = socket(AF_INET, SOCK_STREAM, 0);

	addr_of(L, 1, &sa, port);
	if (fd < 0)
		return 0;
	if (nonblock(fd) != 0) {
		close(fd);
		return 0;
	}
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0 &&
	    errno != EINPROGRESS) {
		close(fd);
		return 0;
	}

	struct conn *c = newconn(L, fd, 0);

	newtoken(L, OP_DIAL, c);
	return 1;
}

/* the connect answered: SO_ERROR is where a refused connection lands,
 * since the failure arrives on the socket rather than from connect().
 */
static int
l_dial_poll(lua_State *L)
{
	struct token *t = luaL_checkudata(L, 1, TOKENMT);
	struct pollfd pfd = { .fd = t->c->fd, .events = POLLOUT };
	int err = 0;
	socklen_t elen = sizeof err;

	if (t->done)
		return 0;
	if (poll(&pfd, 1, 0) <= 0)
		return 0;
	finish(t);
	if (getsockopt(t->c->fd, SOL_SOCKET, SO_ERROR, &err, &elen) != 0 ||
	    err != 0) {
		lua_pushboolean(L, 1);
		return 1;		/* done, and nothing to hand back */
	}
	lua_pushboolean(L, 1);
	lua_getiuservalue(L, 1, 1);	/* the conn this token holds */
	return 2;
}

static int
l_accept_start(lua_State *L)
{
	struct conn *c = checkconn(L, 1);

	newtoken(L, OP_ACCEPT, c);
	return 1;
}

static int
l_accept_poll(lua_State *L)
{
	struct token *t = luaL_checkudata(L, 1, TOKENMT);
	int fd;

	if (t->done)
		return 0;
	fd = accept(t->c->fd, NULL, NULL);
	if (fd < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return 0;
		finish(t);
		lua_pushboolean(L, 1);
		return 1;
	}
	if (nonblock(fd) != 0) {
		close(fd);
		finish(t);
		lua_pushboolean(L, 1);
		return 1;
	}
	finish(t);
	lua_pushboolean(L, 1);
	newconn(L, fd, 0);
	return 2;
}

/* ---- send and recv ---- */

static int
l_send_start(lua_State *L)
{
	struct conn *c = checkconn(L, 1);
	size_t n;
	const char *data = luaL_checklstring(L, 2, &n);

	if (n == 0) {
		lua_pushnil(L);
		return 1;
	}

	/* the bytes are copied because the operation outlives the call:
	 * the lua string is the caller's and may be collected before the
	 * socket has taken all of it.
	 */
	char *copy = malloc(n);

	if (!copy)
		return 0;
	memcpy(copy, data, n);

	lua_pushvalue(L, 1);		/* the conn, for newtoken's uservalue */

	struct token *t = newtoken(L, OP_SEND, c);

	t->buf = copy;
	t->len = n;
	t->off = 0;
	return 1;
}

static int
l_send_poll(lua_State *L)
{
	struct token *t = luaL_checkudata(L, 1, TOKENMT);

	if (t->done)
		return 0;
	while (t->off < t->len) {
		ssize_t w = send(t->c->fd, t->buf + t->off, t->len - t->off,
		    MSG_NOSIGNAL);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return 0;
			finish(t);
			lua_pushboolean(L, 1);
			lua_pushboolean(L, 0);
			return 2;
		}
		t->off += (size_t)w;
	}
	finish(t);
	lua_pushboolean(L, 1);
	lua_pushboolean(L, 1);
	return 2;
}

static int
l_recv_start(lua_State *L)
{
	struct conn *c = checkconn(L, 1);
	lua_Integer maxlen = luaL_optinteger(L, 2, 4096);

	if (maxlen <= 0)
		maxlen = 1;
	if (maxlen > NET_MAXIO)
		maxlen = NET_MAXIO;

	lua_pushvalue(L, 1);

	struct token *t = newtoken(L, OP_RECV, c);

	t->want = (size_t)maxlen;
	return 1;
}

/* a closed connection completes with no data, which is how the task
 * above tells end of stream from "nothing yet".
 */
static int
l_recv_poll(lua_State *L)
{
	struct token *t = luaL_checkudata(L, 1, TOKENMT);
	/* static rather than a frame: this is 64KB, and the bytes become
	 * a lua string before anything else can run on this cpu.
	 */
	static char buf[NET_MAXIO];
	ssize_t r;

	if (t->done)
		return 0;
	do {
		r = recv(t->c->fd, buf, t->want, 0);
	} while (r < 0 && errno == EINTR);
	if (r < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return 0;
		finish(t);
		lua_pushboolean(L, 1);
		return 1;
	}
	finish(t);
	lua_pushboolean(L, 1);
	if (r == 0)
		return 1;		/* the far end is done */
	lua_pushlstring(L, buf, (size_t)r);
	return 2;
}

static int
l_close(lua_State *L)
{
	struct conn *c = luaL_checkudata(L, 1, CONNMT);

	if (!c->closed && c->fd >= 0)
		close(c->fd);
	c->closed = 1;
	return 0;
}

/* the machine has no NIC of its own to name, and the host owns the
 * address. A dhcp client would want both; nothing here runs one.
 */
static int
l_hwaddr(lua_State *L)
{
	lua_pushnil(L);
	return 1;
}

static int
l_setaddr(lua_State *L)
{
	lua_pushboolean(L, 0);
	return 1;
}

static const luaL_Reg netlib[] = {
	{ "listen", l_listen },
	{ "dial_start", l_dial_start },
	{ "dial_poll", l_dial_poll },
	{ "accept_start", l_accept_start },
	{ "accept_poll", l_accept_poll },
	{ "send_start", l_send_start },
	{ "send_poll", l_send_poll },
	{ "recv_start", l_recv_start },
	{ "recv_poll", l_recv_poll },
	{ "close", l_close },
	{ "hwaddr", l_hwaddr },
	{ "setaddr", l_setaddr },
	{ NULL, NULL }
};

int luaopen_los_platform_tcp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	luaL_newmetatable(L, CONNMT);
	lua_pushcfunction(L, conn_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newmetatable(L, TOKENMT);
	lua_pushcfunction(L, token_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newlib(L, netlib);
	return 1;
}
