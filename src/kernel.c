/* cooperative mach-lite kernel: lua_State procs, ports, rights.
 *
 * - each proc = own lua_State (heap isolation) + one lua thread the
 *   chunk runs on
 * - ports = kernel-side fifo of serialized messages
 * - rights = small-int handles in a per-proc table; lua never sees
 *   pointers. handle 0 is always the proc's own receive port.
 * - blocking recv/readline is lua-side sugar over tryrecv + block
 * - preemption via count hook: busy loops can't starve the machine
 * - keyboard: kernel pumps ConIn into a port whose receive right is
 *   given to proc 0
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "efi.h"
#include "kernel.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define MAXPROCS	32
#define MAXPORTS	128
#define MAXRIGHTS	64
#define HOOKCOUNT	200000
#define MAXMSG		(64 * 1024)
#define MAXDEPTH	16

enum { DEAD, READY, BLOCKED };

struct kmsg {
	struct kmsg *next;
	size_t len;
	unsigned char data[];
};

struct kport {
	int used;
	struct kmsg *head, *tail;
};

struct right {
	struct kport *port;
	int recv;
	int used;
};

#define MAXWSET 8

struct kproc {
	int status;
	int id;
	lua_State *L;		/* owning state */
	lua_State *co;		/* thread the chunk runs on */
	struct kport *waiting;	/* blocked on this port */
	struct kport *wset[MAXWSET];	/* or on any of these (alt) */
	int nwset;
	struct right rights[MAXRIGHTS];
};

static struct kproc procs[MAXPROCS];
static struct kport ports[MAXPORTS];
static struct kport *kbdport;
static int nlive;

extern void console_write(const char *s, size_t n);
void luaL_openlibs(lua_State *L);	/* our linit */

static void
kputs(const char *s)
{
	console_write(s, strlen(s));
}

/* ---- ports and rights ---- */

static struct kport *
port_new(void)
{
	for (int i = 0; i < MAXPORTS; i++)
		if (!ports[i].used) {
			ports[i].used = 1;
			ports[i].head = ports[i].tail = 0;
			return &ports[i];
		}
	return 0;
}

static int
right_new(struct kproc *p, struct kport *port, int recv)
{
	for (int i = 0; i < MAXRIGHTS; i++)
		if (!p->rights[i].used) {
			p->rights[i].used = 1;
			p->rights[i].port = port;
			p->rights[i].recv = recv;
			return i;
		}
	return -1;
}

static struct right *
right_get(struct kproc *p, lua_Integer h)
{
	if (h < 0 || h >= MAXRIGHTS || !p->rights[h].used)
		return 0;
	return &p->rights[h];
}

/* ---- serializer ----
 * tags: N nil, T true, F false, I int64, D double, S u32+bytes,
 * B u32 npairs then k,v..., R u8 portindex u8 recv
 */

struct wbuf {
	unsigned char *p;
	size_t len, cap;
};

static int
wput(struct wbuf *w, const void *src, size_t n)
{
	if (w->len + n > w->cap) {
		size_t ncap = w->cap ? w->cap * 2 : 256;

		while (ncap < w->len + n)
			ncap *= 2;
		if (ncap > MAXMSG)
			return -1;
		unsigned char *np = realloc(w->p, ncap);

		if (!np)
			return -1;
		w->p = np;
		w->cap = ncap;
	}
	memcpy(w->p + w->len, src, n);
	w->len += n;
	return 0;
}

static int
wbyte(struct wbuf *w, unsigned char c)
{
	return wput(w, &c, 1);
}

static int
serialize(lua_State *L, int idx, struct wbuf *w, struct kproc *sender,
    int depth)
{
	if (depth > MAXDEPTH)
		return -1;
	idx = lua_absindex(L, idx);

	switch (lua_type(L, idx)) {
	case LUA_TNIL:
		return wbyte(w, 'N');
	case LUA_TBOOLEAN:
		return wbyte(w, lua_toboolean(L, idx) ? 'T' : 'F');
	case LUA_TNUMBER:
		if (lua_isinteger(L, idx)) {
			lua_Integer v = lua_tointeger(L, idx);

			if (wbyte(w, 'I'))
				return -1;
			return wput(w, &v, sizeof v);
		} else {
			lua_Number v = lua_tonumber(L, idx);

			if (wbyte(w, 'D'))
				return -1;
			return wput(w, &v, sizeof v);
		}
	case LUA_TSTRING: {
		size_t n;
		const char *s = lua_tolstring(L, idx, &n);
		unsigned int len = n;

		if (wbyte(w, 'S') || wput(w, &len, sizeof len))
			return -1;
		return wput(w, s, n);
	}
	case LUA_TTABLE: {
		/* {__right = handle} transfers a right */
		lua_getfield(L, idx, "__right");
		if (lua_isinteger(L, -1)) {
			struct right *r = right_get(sender,
			    lua_tointeger(L, -1));

			lua_pop(L, 1);
			if (!r)
				return -1;
			unsigned char pi = (unsigned char)(r->port - ports);

			if (wbyte(w, 'R') || wbyte(w, pi))
				return -1;
			return wbyte(w, (unsigned char)r->recv);
		}
		lua_pop(L, 1);

		unsigned int n = 0;
		size_t countpos = w->len;

		if (wbyte(w, 'B') || wput(w, &n, sizeof n))
			return -1;
		lua_pushnil(L);
		while (lua_next(L, idx)) {
			if (serialize(L, -2, w, sender, depth + 1) ||
			    serialize(L, -1, w, sender, depth + 1)) {
				lua_pop(L, 2);
				return -1;
			}
			lua_pop(L, 1);
			n++;
		}
		memcpy(w->p + countpos + 1, &n, sizeof n);
		return 0;
	}
	default:
		return -1;	/* functions, userdata: no travel */
	}
}

static int
deserialize(lua_State *L, const unsigned char *p, size_t len, size_t *off,
    struct kproc *receiver)
{
	if (*off >= len)
		return -1;
	unsigned char tag = p[(*off)++];

	switch (tag) {
	case 'N':
		lua_pushnil(L);
		return 0;
	case 'T':
		lua_pushboolean(L, 1);
		return 0;
	case 'F':
		lua_pushboolean(L, 0);
		return 0;
	case 'I': {
		lua_Integer v;

		if (*off + sizeof v > len)
			return -1;
		memcpy(&v, p + *off, sizeof v);
		*off += sizeof v;
		lua_pushinteger(L, v);
		return 0;
	}
	case 'D': {
		lua_Number v;

		if (*off + sizeof v > len)
			return -1;
		memcpy(&v, p + *off, sizeof v);
		*off += sizeof v;
		lua_pushnumber(L, v);
		return 0;
	}
	case 'S': {
		unsigned int n;

		if (*off + sizeof n > len)
			return -1;
		memcpy(&n, p + *off, sizeof n);
		*off += sizeof n;
		if (*off + n > len)
			return -1;
		lua_pushlstring(L, (const char *)p + *off, n);
		*off += n;
		return 0;
	}
	case 'B': {
		unsigned int n;

		if (*off + sizeof n > len)
			return -1;
		memcpy(&n, p + *off, sizeof n);
		*off += sizeof n;
		lua_createtable(L, 0, n);
		for (unsigned int i = 0; i < n; i++) {
			if (deserialize(L, p, len, off, receiver) ||
			    deserialize(L, p, len, off, receiver))
				return -1;
			lua_settable(L, -3);
		}
		return 0;
	}
	case 'R': {
		if (*off + 2 > len)
			return -1;
		unsigned char pi = p[(*off)++];
		unsigned char recv = p[(*off)++];

		if (pi >= MAXPORTS || !ports[pi].used)
			return -1;
		int h = right_new(receiver, &ports[pi], recv);

		if (h < 0)
			return -1;
		lua_createtable(L, 0, 1);
		lua_pushinteger(L, h);
		lua_setfield(L, -2, "__right");
		return 0;
	}
	default:
		return -1;
	}
}

/* ---- message delivery ---- */

static void
wake_receivers(struct kport *port)
{
	for (int i = 0; i < MAXPROCS; i++) {
		struct kproc *p = &procs[i];

		if (p->status != BLOCKED)
			continue;
		if (p->waiting == port)
			goto wake;
		for (int j = 0; j < p->nwset; j++)
			if (p->wset[j] == port)
				goto wake;
		continue;
wake:
		p->status = READY;
		p->waiting = 0;
		p->nwset = 0;
	}
}

static int
port_push(struct kport *port, const unsigned char *data, size_t len)
{
	struct kmsg *m = malloc(sizeof *m + len);

	if (!m)
		return -1;
	m->next = 0;
	m->len = len;
	memcpy(m->data, data, len);
	if (port->tail)
		port->tail->next = m;
	else
		port->head = m;
	port->tail = m;
	wake_receivers(port);
	return 0;
}

/* ---- lua api (proc pointer in upvalue) ---- */

static struct kproc *
self(lua_State *L)
{
	return lua_touserdata(L, lua_upvalueindex(1));
}

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));
	struct wbuf w = { 0, 0, 0 };

	if (!r)
		return luaL_error(L, "bad right");
	luaL_checkany(L, 2);
	if (serialize(L, 2, &w, p, 0)) {
		free(w.p);
		return luaL_error(L, "unserializable message");
	}
	int rc = port_push(r->port, w.p, w.len);

	free(w.p);
	if (rc)
		return luaL_error(L, "port full");
	return 0;
}

static int
api_tryrecv(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (!r->port->head) {
		lua_pushboolean(L, 0);
		return 1;
	}
	struct kmsg *m = r->port->head;

	r->port->head = m->next;
	if (!r->port->head)
		r->port->tail = 0;

	size_t off = 0;

	lua_pushboolean(L, 1);
	if (deserialize(L, m->data, m->len, &off, p)) {
		free(m);
		return luaL_error(L, "corrupt message");
	}
	free(m);
	return 2;
}

static int
api_block(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (r->port->head)
		return 0;	/* message already there, don't sleep */
	p->status = BLOCKED;
	p->waiting = r->port;
	return lua_yield(L, 0);
}

/* block until any of a set of receive rights has a message (port set) */
static int
api_altblock(lua_State *L)
{
	struct kproc *p = self(L);
	int n;

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1 || n > MAXWSET)
		return luaL_error(L, "altblock: 1..%d ports", MAXWSET);

	p->nwset = 0;
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, luaL_checkinteger(L, -1));

		lua_pop(L, 1);
		if (!r || !r->recv)
			return luaL_error(L, "altblock: bad receive right");
		if (r->port->head) {
			p->nwset = 0;
			return 0;	/* already ready, don't sleep */
		}
		p->wset[p->nwset++] = r->port;
	}
	p->status = BLOCKED;
	return lua_yield(L, 0);
}

extern void uart_tx(const char *s, unsigned long n);

static int
api_serwrite(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	uart_tx(s, n);
	return 0;
}

static int
api_yield(lua_State *L)
{
	return lua_yield(L, 0);
}

static int
api_newport(lua_State *L)
{
	struct kproc *p = self(L);
	struct kport *port = port_new();

	if (!port)
		return luaL_error(L, "out of ports");
	int h = right_new(p, port, 1);

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, h);
	return 1;
}

static int proc_new(const char *code, size_t codelen, const char *chunkname,
    int is_file);

static int
api_spawn(lua_State *L)
{
	struct kproc *p = self(L);
	size_t n;
	const char *code = luaL_checklstring(L, 1, &n);
	int pid = proc_new(code, n, "=spawn", 0);

	if (pid < 0)
		return luaL_error(L, "spawn failed");
	/* hand parent a send right on the child's self port */
	int h = right_new(p, procs[pid].rights[0].port, 0);

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, pid);
	lua_pushinteger(L, h);
	return 2;
}

static int
api_self(lua_State *L)
{
	lua_pushinteger(L, self(L)->id);
	return 1;
}

static int
api_procs(lua_State *L)
{
	lua_newtable(L);
	for (int i = 0, n = 1; i < MAXPROCS; i++)
		if (procs[i].status != DEAD) {
			lua_pushinteger(L, procs[i].id);
			lua_rawseti(L, -2, n++);
		}
	return 1;
}

static const luaL_Reg kapi[] = {
	{ "send", api_send },
	{ "tryrecv", api_tryrecv },
	{ "block", api_block },
	{ "altblock", api_altblock },
	{ "serwrite", api_serwrite },
	{ "yield", api_yield },
	{ "newport", api_newport },
	{ "spawn", api_spawn },
	{ "self", api_self },
	{ "procs", api_procs },
	{ NULL, NULL }
};

/* ---- proc lifecycle ---- */

static void
preempt_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	if (lua_isyieldable(L))
		lua_yield(L, 0);
}

static int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file)
{
	struct kproc *p = 0;

	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status == DEAD) {
			p = &procs[i];
			break;
		}
	if (!p)
		return -1;

	memset(p->rights, 0, sizeof p->rights);
	p->L = luaL_newstate();
	if (!p->L)
		return -1;
	p->id = (int)(p - procs);
	luaL_openlibs(p->L);

	/* self port = right handle 0 */
	struct kport *port = port_new();

	if (!port || right_new(p, port, 1) != 0) {
		lua_close(p->L);
		return -1;
	}

	/* kernel api, with the proc as upvalue */
	lua_getglobal(p->L, "los");
	lua_pushlightuserdata(p->L, p);
	luaL_setfuncs(p->L, kapi, 1);
	lua_pop(p->L, 1);

	p->co = lua_newthread(p->L);
	luaL_ref(p->L, LUA_REGISTRYINDEX);	/* anchor the thread */

	int rc;

	if (is_file)
		rc = luaL_loadfile(p->co, code);
	else
		rc = luaL_loadbuffer(p->co, code, codelen, chunkname);
	if (rc != LUA_OK) {
		kputs("proc load error: ");
		kputs(lua_tostring(p->co, -1));
		kputs("\n");
		lua_close(p->L);
		return -1;
	}

	/* prelude gives every proc the lua-side sugar (recv, readline) */
	if (luaL_dofile(p->L, "/prelude.lua") != LUA_OK)
		lua_pop(p->L, 1);	/* optional; ignore if missing */

	lua_sethook(p->co, preempt_hook, LUA_MASKCOUNT, HOOKCOUNT);
	p->status = READY;
	p->waiting = 0;
	nlive++;
	return p->id;
}

static void
proc_kill(struct kproc *p, const char *why)
{
	if (why) {
		char buf[128];

		snprintf(buf, sizeof buf, "proc %d died: %s\n", p->id, why);
		kputs(buf);
	}
	lua_close(p->L);
	p->status = DEAD;
	p->L = 0;
	p->co = 0;
	nlive--;
}

/* ---- serial pump (9p wire on com2) ---- */

extern void uart_init(void);
extern int uart_rx(void);

static struct kport *serport;

static void
pump_serial(void)
{
	unsigned char buf[5 + 256];
	unsigned int n = 0;
	int c;

	while (n < 256 && (c = uart_rx()) >= 0)
		buf[5 + n++] = (unsigned char)c;
	if (n == 0)
		return;
	/* serialized string message: tag, u32 len, bytes */
	buf[0] = 'S';
	memcpy(buf + 1, &n, 4);
	port_push(serport, buf, 5 + n);
}

/* ---- keyboard pump ---- */

static void
pump_keyboard(void)
{
	EFI_INPUT_KEY key;

	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_SUCCESS) {
		/* serialized one-char string: tag, u32 len, byte */
		unsigned char msg[6] = { 'S', 1, 0, 0, 0, 0 };

		if (key.UnicodeChar == 0 || key.UnicodeChar >= 0x80)
			continue;
		msg[5] = (unsigned char)key.UnicodeChar;
		port_push(kbdport, msg, sizeof msg);
	}
}

/* ---- kernel ---- */

int
kernel_init(void)
{
	uart_init();
	kbdport = port_new();
	serport = port_new();
	return (kbdport && serport) ? 0 : -1;
}

int
kernel_spawn_file(const char *path)
{
	int pid = proc_new(path, 0, 0, 1);

	if (pid >= 0 && kbdport) {
		/* proc 0: handle 1 = keyboard, handle 2 = serial */
		right_new(&procs[pid], kbdport, 1);
		right_new(&procs[pid], serport, 1);
	}
	return pid;
}

void
kernel_run(void)
{
	while (nlive > 0) {
		int ran = 0;

		pump_keyboard();
		pump_serial();
		for (int i = 0; i < MAXPROCS; i++) {
			struct kproc *p = &procs[i];

			if (p->status != READY)
				continue;
			ran = 1;

			int nres = 0;
			int rc = lua_resume(p->co, 0, 0, &nres);

			lua_pop(p->co, nres);
			if (rc == LUA_YIELD)
				continue;	/* READY or BLOCKED */
			if (rc == LUA_OK)
				proc_kill(p, 0);
			else
				proc_kill(p, lua_tostring(p->co, -1));
		}
		if (!ran) {
			/* everyone blocked; serial has no event, so poll */
			BS->Stall(500);
		}
	}
}
