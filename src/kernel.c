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
#include "net.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "platform.h"

#define MAXPROCS	32
#define MAXPORTS	128
#define MAXRIGHTS	64
#define REDUCTIONS	25000	/* default instruction budget per slice */
#define MAXMSG		(64 * 1024)
#define MAXDEPTH	16
#define MAXMSGRIGHTS	8	/* rights per message */
#define MAXWATCH	8	/* monitors per proc */

enum { DEAD, READY, BLOCKED };
enum { PRIV_NONE, PRIV_CONS, PRIV_WIRE, PRIV_POWER, PRIV_NET };

struct kmsg {
	struct kmsg *next;
	size_t len;
	/* ports referenced by in-flight rights in this message. they hold
	 * a ref each so a port can't be freed (and its index reused) while
	 * the only right to it sits in a queue.
	 */
	unsigned char refs[MAXMSGRIGHTS];
	int nrefs;
	unsigned char data[];
};

struct kport {
	int used;
	int nrights;	/* rights + in-flight message refs + kernel refs */
	int nrecv;	/* receive rights among those */
	int dead;	/* no receive right left; sends are dropped */
	struct kmsg *head, *tail;
};

struct right {
	struct kport *port;
	int recv;
	int used;
};

/* a proc holds at most MAXRIGHTS distinct rights, so it can never park
 * on more than that many distinct ports; size the wait set to match so
 * a legitimate gather can't be rejected.
 */
#define MAXWSET MAXRIGHTS

struct kproc {
	int status;
	int id;			/* unique forever; slots are reused, ids not */
	lua_State *L;		/* owning state */
	lua_State *co;		/* thread the chunk runs on */
	struct kport *waiting;	/* blocked on this port */
	struct kport *wset[MAXWSET];	/* or on any of these (alt) */
	int nwset;
	struct right rights[MAXRIGHTS];
	int watchers[MAXWATCH];	/* pids to notify when this proc dies */
	int nwatch;
	int reductions;		/* instruction budget per slice */
	size_t mem_used;	/* live bytes in this proc's lua heap */
	size_t mem_peak;
	size_t mem_limit;	/* 0 = unlimited */
};

static struct kproc procs[MAXPROCS];
static struct kport ports[MAXPORTS];
static struct kport *kbdport;
static int nlive;
static int nextpid;

/* who's running right now. kernel_run sets this before every
 * lua_resume and clears it after. plain C code with no lua_State
 * (stdio.c's fopen, called via liolib.c with no proc identity
 * threaded through) uses this to find out who's asking -- the only
 * way to check a capability from a context where self(L) isn't
 * available at all.
 */
static struct kproc *current_proc;

/* disk gates write/append only -- read is deliberately ambient (see
 * stdio.c's fopen): the threat model is buggy lua, not hostile users
 * (DESIGN.md non-goals), nothing on the esp is confidentiality-
 * sensitive, and a stray read can't corrupt anything the way a
 * runaway write can. write still can't use the exclusive-task trick
 * cons/wire/power do (liolib.c calls our fopen() as plain C with no
 * lua_State, so there's no require()-registration boundary to
 * police); diskport is a reserved, message-free capability token,
 * holding any right to it is what fopen() checks for writes.
 */
static struct kport *diskport;

/* dynamic wait-set: device layers whose completions are token/Event
 * based (unlike the byte-stream pumps above, which are polled every
 * iteration) register the Event they're waiting on here, so
 * kernel_run's idle sleep can include it. net.c (EFI TCP4) is the
 * first user -- Connect/Accept/Transmit/Receive all take a token
 * whose completion is signaled by an Event, not by bytes just being
 * "there" to poll.
 */
#define MAXWAITEVENTS 16
static EFI_EVENT extra_wait_events[MAXWAITEVENTS];
static int nextra_wait_events;

int
kernel_register_wait_event(EFI_EVENT ev)
{
	if (nextra_wait_events >= MAXWAITEVENTS)
		return -1;
	extra_wait_events[nextra_wait_events++] = ev;
	return 0;
}

void
kernel_unregister_wait_event(EFI_EVENT ev)
{
	for (int i = 0; i < nextra_wait_events; i++)
		if (extra_wait_events[i] == ev) {
			extra_wait_events[i] =
			    extra_wait_events[--nextra_wait_events];
			return;
		}
}

static int port_push(struct kport *port, const unsigned char *data,
    size_t len, const unsigned char *refs, int nrefs);

/* net's own wakeup: a kernel-owned port, exactly like kbdport/serport,
 * except fed by an EFI event-notify callback instead of a polled pump
 * -- net.c's completions are token/Event based, not "bytes just show
 * up to poll." the notify runs with no lua involved at all (it's an
 * EFIAPI callback the firmware invokes directly), so it can only ever
 * touch plain kernel state; port_push is exactly that, already safe
 * to call from anywhere. whoever holds netport's recv right (the net
 * task, once it exists) just does an ordinary thread.recv -- same
 * proven wakeup path as every other blocking primitive here, no new
 * primitive with its own race to get wrong.
 */
static struct kport *netport;

/* true once net_init() has located tcp4 and the net task has been (or
 * will be) spawned; guards pump_net so it doesn't push into netport
 * forever with no reader when there's no NIC -- netport would never
 * gain a receive right in that case, so nothing would ever mark it
 * dead, and the queue would grow unbounded.
 */
static int have_net;

static void EFIAPI
net_event_notify(EFI_EVENT ev, void *ctx)
{
	(void)ev;
	(void)ctx;
	/* every message needs at least a serializer tag; an empty buffer
	 * has none and the deserializer correctly refuses it as corrupt.
	 * this is just a wakeup ping -- net.lua doesn't look at the
	 * value, so a bare nil (tag 'N', one byte) is enough.
	 */
	if (netport)
		port_push(netport, (const unsigned char *)"N", 1, 0, 0);
}

/* net.c calls this instead of BS->CreateEvent directly: wires the
 * notify above, and registers the event in kernel_run's dynamic wait
 * set so the machine wakes promptly (bounded otherwise by the 1ms
 * tick, which would still be correct, just slightly slower).
 */
EFI_EVENT
kernel_new_net_event(void)
{
	EFI_EVENT ev;

	if (BS->CreateEvent(EVT_NOTIFY_SIGNAL, TPL_CALLBACK,
	    (void *)net_event_notify, 0, &ev) != EFI_SUCCESS)
		return 0;
	if (kernel_register_wait_event(ev) != 0) {
		BS->CloseEvent(ev);
		return 0;
	}
	return ev;
}

static struct kproc *
find_proc(int pid)
{
	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status != DEAD && procs[i].id == pid)
			return &procs[i];
	return 0;
}

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
			ports[i].nrights = 0;
			ports[i].nrecv = 0;
			ports[i].dead = 0;
			return &ports[i];
		}
	return 0;
}

static void port_unref(struct kport *port);

/* free one message, releasing the in-flight right refs it carries */
static void
msg_free(struct kmsg *m)
{
	for (int i = 0; i < m->nrefs; i++)
		port_unref(&ports[m->refs[i]]);
	free(m);
}

/* flush the queue (delivery no longer possible) */
static void
port_flush(struct kport *port)
{
	struct kmsg *m = port->head;

	port->head = port->tail = 0;
	while (m) {
		struct kmsg *next = m->next;

		msg_free(m);
		m = next;
	}
}

/* drop one reference; the last ref frees the port. dropping the last
 * *receive* right marks the port dead and flushes the queue -- nobody
 * can ever take those messages. flushing may recursively unref other
 * ports whose only rights were in the flushed messages.
 */
static void
port_unref(struct kport *port)
{
	if (--port->nrights <= 0) {
		port_flush(port);
		port->used = 0;
		port->dead = 0;
		port->nrights = 0;
		port->nrecv = 0;
		return;
	}
	if (port->nrecv == 0 && !port->dead) {
		port->dead = 1;
		port_flush(port);
	}
}

static int
right_new(struct kproc *p, struct kport *port, int recv)
{
	for (int i = 0; i < MAXRIGHTS; i++)
		if (!p->rights[i].used) {
			p->rights[i].used = 1;
			p->rights[i].port = port;
			p->rights[i].recv = recv;
			port->nrights++;
			if (recv)
				port->nrecv++;
			return i;
		}
	return -1;
}

static void
right_drop(struct right *r)
{
	struct kport *port = r->port;

	r->used = 0;
	if (r->recv)
		port->nrecv--;
	port_unref(port);
}

static struct right *
right_get(struct kproc *p, lua_Integer h)
{
	if (h < 0 || h >= MAXRIGHTS || !p->rights[h].used)
		return 0;
	return &p->rights[h];
}

/* grant at a specific index rather than the first free slot. used only
 * for the boot-time CONS/WIRE/POWER/DISK grants, so a driver that
 * fails to spawn leaves a hole at its fixed handle number instead of
 * shifting every later grant into the wrong slot.
 */
static int
right_new_at(struct kproc *p, int idx, struct kport *port, int recv)
{
	if (idx < 0 || idx >= MAXRIGHTS || p->rights[idx].used)
		return -1;
	p->rights[idx].used = 1;
	p->rights[idx].port = port;
	p->rights[idx].recv = recv;
	port->nrights++;
	if (recv)
		port->nrecv++;
	return idx;
}

/* ---- serializer ----
 * tags: N nil, T true, F false, I int64, D double, S u32+bytes,
 * B u32 npairs then k,v..., R u8 portindex u8 recv
 */

struct wbuf {
	unsigned char *p;
	size_t len, cap;
	/* ports referenced by rights serialized into this message; each
	 * holds a ref taken at serialize time (released on send failure,
	 * or by msg_free once delivered/flushed)
	 */
	unsigned char refs[MAXMSGRIGHTS];
	int nrefs;
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
		/* {__right = handle} transfers a right. if __right is present
		 * but not an integer handle it's a mistake (e.g. a float);
		 * refuse it rather than silently shipping the table as data
		 * and dropping the intended capability.
		 */
		lua_getfield(L, idx, "__right");
		if (!lua_isnil(L, -1)) {
			if (!lua_isinteger(L, -1)) {
				lua_pop(L, 1);
				return -1;
			}
			struct right *r = right_get(sender,
			    lua_tointeger(L, -1));

			lua_pop(L, 1);
			if (!r || w->nrefs >= MAXMSGRIGHTS)
				return -1;
			unsigned char pi = (unsigned char)(r->port - ports);

			if (wbyte(w, 'R') || wbyte(w, pi))
				return -1;
			if (wbyte(w, (unsigned char)r->recv))
				return -1;
			/* in-flight ref keeps the port alive in the queue */
			w->refs[w->nrefs++] = pi;
			r->port->nrights++;
			return 0;
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
    struct kproc *receiver, int depth)
{
	if (depth > MAXDEPTH)
		return -1;
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
		/* each pair is >= 2 bytes (two tags); reject a count that
		 * can't fit in what's left so a corrupt n can't drive a
		 * huge lua_createtable preallocation.
		 */
		if (n > (len - *off) / 2)
			return -1;
		lua_createtable(L, 0, n);
		for (unsigned int i = 0; i < n; i++) {
			if (deserialize(L, p, len, off, receiver, depth + 1) ||
			    deserialize(L, p, len, off, receiver, depth + 1))
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

/* queue a message. refs/nrefs are in-flight right refs (may be null).
 * a dead port silently drops -- erlang semantics, the sender learns
 * from the monitor, not the send.
 */
static int
port_push(struct kport *port, const unsigned char *data, size_t len,
    const unsigned char *refs, int nrefs)
{
	if (port->dead) {
		for (int i = 0; i < nrefs; i++)
			port_unref(&ports[refs[i]]);
		return 0;
	}

	struct kmsg *m = malloc(sizeof *m + len);

	if (!m)
		return -1;
	m->next = 0;
	m->len = len;
	m->nrefs = nrefs;
	for (int i = 0; i < nrefs; i++)
		m->refs[i] = refs[i];
	memcpy(m->data, data, len);
	if (port->tail)
		port->tail->next = m;
	else
		port->head = m;
	port->tail = m;
	wake_receivers(port);
	return 0;
}

/* ---- lua api (proc pointer lives in the state's extra space) ---- */

static struct kproc *
self(lua_State *L)
{
	return *(struct kproc **)lua_getextraspace(L);
}

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));
	struct wbuf w = { 0 };

	if (!r)
		return luaL_error(L, "bad right");
	luaL_checkany(L, 2);
	if (serialize(L, 2, &w, p, 0)) {
		/* release refs taken for rights serialized before the
		 * failure point
		 */
		for (int i = 0; i < w.nrefs; i++)
			port_unref(&ports[w.refs[i]]);
		free(w.p);
		return luaL_error(L, "unserializable message");
	}
	if (r->port->dead) {
		for (int i = 0; i < w.nrefs; i++)
			port_unref(&ports[w.refs[i]]);
		free(w.p);
		lua_pushboolean(L, 0);	/* dead port: dropped */
		return 1;
	}
	int rc = port_push(r->port, w.p, w.len, w.refs, w.nrefs);

	free(w.p);
	if (rc)
		return luaL_error(L, "out of memory queueing message");
	lua_pushboolean(L, 1);
	return 1;
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
	if (deserialize(L, m->data, m->len, &off, p, 0)) {
		msg_free(m);
		return luaL_error(L, "corrupt message");
	}
	/* receiver now holds its own refs (right_new); drop in-flight */
	msg_free(m);
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
	if (n < 1)
		return luaL_error(L, "altblock: need at least one port");

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
		/* dedup: the caller may list the same handle more than once
		 * (alt cases share ports). distinct ports are bounded by
		 * MAXRIGHTS == MAXWSET, so the set can never overflow.
		 */
		int seen = 0;
		for (int j = 0; j < p->nwset; j++)
			if (p->wset[j] == r->port) {
				seen = 1;
				break;
			}
		if (!seen)
			p->wset[p->nwset++] = r->port;
	}
	p->status = BLOCKED;
	return lua_yield(L, 0);
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
    int is_file, int reductions, size_t mem_limit, int priv);
static void notify_exit(struct kproc *watcher, int pid, const char *reason);

static int
api_spawn(lua_State *L)
{
	struct kproc *p = self(L);
	size_t n;
	const char *code = luaL_checklstring(L, 1, &n);
	int reductions = 0;
	size_t mem_limit = 0;

	if (!lua_isnoneornil(L, 2)) {
		luaL_checktype(L, 2, LUA_TTABLE);
		lua_getfield(L, 2, "reductions");
		if (!lua_isnil(L, -1))
			reductions = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "mem");
		if (!lua_isnil(L, -1))
			mem_limit = (size_t)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
	}

	/* sys.spawn can never mint a privileged (cons/wire/power-class)
	 * proc: PRIV_NONE is hardwired here. only the kernel's own boot
	 * sequence (spawn_cons/spawn_wire/spawn_power) sets a real priv
	 * value, never reachable from lua.
	 */
	int pid = proc_new(code, n, "=spawn", 0, reductions, mem_limit,
	    PRIV_NONE);

	if (pid < 0)
		return luaL_error(L, "spawn failed");

	struct kproc *child = find_proc(pid);

	if (!child)
		return luaL_error(L, "spawn: child vanished");
	/* hand parent a send right on the child's self port */
	int h = right_new(p, child->rights[0].port, 0);

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, pid);
	lua_pushinteger(L, h);
	return 2;
}

/* watch a proc: when it dies, {exit=pid, normal=, reason=?} arrives on
 * our self port. watching a dead/unknown pid delivers noproc at once.
 */
static int
api_monitor(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc(pid);

	if (!target) {
		notify_exit(p, pid, "noproc");
		lua_pushboolean(L, 1);
		return 1;
	}
	if (target == p)
		return luaL_error(L, "cannot monitor self");
	for (int i = 0; i < target->nwatch; i++)
		if (target->watchers[i] == p->id) {
			lua_pushboolean(L, 1);
			return 1;	/* already watching */
		}
	if (target->nwatch >= MAXWATCH)
		return luaL_error(L, "too many watchers");
	target->watchers[target->nwatch++] = p->id;
	lua_pushboolean(L, 1);
	return 1;
}

/* explicitly drop a right. handle 0 (self port) is not closable. */
static int
api_close(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);
	struct right *r = right_get(p, h);

	if (!r)
		return luaL_error(L, "bad right");
	if (h == 0)
		return luaL_error(L, "cannot close self port");
	right_drop(r);
	return 0;
}

static void preempt_hook(lua_State *L, lua_Debug *ar);

/* install the kernel's count hook on a coroutine. lua-side hook
 * functions cannot yield ("attempt to yield across a C-call
 * boundary"), so in-state schedulers (los.thread) must use this to
 * preempt busy threads.
 */
static int
api_preempt(lua_State *L)
{
	lua_State *co = lua_tothread(L, 1);
	lua_Integer count = luaL_optinteger(L, 2, REDUCTIONS);

	if (!co)
		return luaL_error(L, "preempt: not a coroutine");
	lua_sethook(co, preempt_hook, LUA_MASKCOUNT, (int)count);
	return 0;
}

/* memory accounting: meminfo([pid]) -> used, peak, limit */
static int
api_meminfo(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	return 3;
}

static int
api_stats(lua_State *L)
{
	int nports = 0, nprocs = 0;

	for (int i = 0; i < MAXPORTS; i++)
		if (ports[i].used)
			nports++;
	for (int i = 0; i < MAXPROCS; i++)
		if (procs[i].status != DEAD)
			nprocs++;
	lua_createtable(L, 0, 2);
	lua_pushinteger(L, nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, nprocs);
	lua_setfield(L, -2, "procs");
	return 1;
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

extern unsigned long long platform_ticks(void);

static int
api_ticks(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)platform_ticks());
	return 1;
}

static const luaL_Reg kapi[] = {
	{ "send", api_send },
	{ "tryrecv", api_tryrecv },
	{ "block", api_block },
	{ "altblock", api_altblock },
	{ "yield", api_yield },
	{ "newport", api_newport },
	{ "spawn", api_spawn },
	{ "monitor", api_monitor },
	{ "close", api_close },
	{ "stats", api_stats },
	{ "meminfo", api_meminfo },
	{ "preempt", api_preempt },
	{ "self", api_self },
	{ "procs", api_procs },
	{ "ticks", api_ticks },
	{ NULL, NULL }
};

extern int luaopen_los_efi(lua_State *L);		/* los.c: firmware info */
extern int luaopen_los_platform_cons(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_wire(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_power(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_net(lua_State *L);	/* net.c */

/* the los.sys module: the microkernel abi (ports, rights, procs) plus
 * kernel-owned primitives that outlive efi (ticks). registered in
 * package.preload by proc_new; a chunk pulls it in with an explicit
 * require("los.sys"). the proc pointer comes from the state's extra
 * space, so the api needs no upvalues.
 */
static int
los_sys_open(lua_State *L)
{
	luaL_newlib(L, kapi);

	/* well-known right handles. 0 (own receive port) holds for every
	 * proc. 1/2/3 are send-rights to the cons/wire/power tasks, the
	 * only procs anywhere with the corresponding los.platform.*
	 * module registered -- talking to any of them is a message, never
	 * a direct call. 4 is the disk-write capability (a checked right,
	 * not an exclusive task -- see fopen()/kernel_current_has_disk());
	 * reading a file needs no right at all, only writing/appending
	 * does. 5 is a send-right to net, granted only when a NIC was
	 * actually found at boot (see have_net) -- unlike the other four,
	 * a missing net task is the normal case on hardware without one,
	 * not a boot failure. all are handed to the boot payload (init.lua
	 * or a test payload) at spawn; ordinary sys.spawn children get
	 * none of them by default.
	 */
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "SELF");
	lua_pushinteger(L, 1);
	lua_setfield(L, -2, "CONS");
	lua_pushinteger(L, 2);
	lua_setfield(L, -2, "WIRE");
	lua_pushinteger(L, 3);
	lua_setfield(L, -2, "POWER");
	lua_pushinteger(L, 4);
	lua_setfield(L, -2, "DISK");
	lua_pushinteger(L, 5);
	lua_setfield(L, -2, "NET");
	return 1;
}

/* ---- proc lifecycle ---- */

/* lua allocator with per-proc accounting. note lua's convention: when
 * ptr is NULL, osize carries the object type, not a size.
 */
static void *
kalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	struct kproc *p = ud;
	size_t real_osize = ptr ? osize : 0;

	if (nsize == 0) {
		free(ptr);
		p->mem_used -= real_osize;
		return 0;
	}
	/* enforce the limit only on growth so gc/shrink always succeeds */
	if (p->mem_limit && nsize > real_osize &&
	    p->mem_used - real_osize + nsize > p->mem_limit)
		return 0;

	void *q = realloc(ptr, nsize);

	if (!q)
		return 0;
	p->mem_used += nsize - real_osize;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	return q;
}

static void
preempt_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	if (lua_isyieldable(L))
		lua_yield(L, 0);
}

static int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file,
    int reductions, size_t mem_limit, int priv)
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
	p->nwatch = 0;
	p->reductions = reductions > 0 ? reductions : REDUCTIONS;
	p->mem_used = 0;
	p->mem_peak = 0;
	/* the limit goes live only after setup: base state + libraries
	 * are counted but never refused, so a tiny limit can't panic
	 * openlibs. the chunk's first over-limit allocation then fails
	 * inside the protected resume (clean LUA_ERRMEM death).
	 */
	p->mem_limit = 0;
	p->L = lua_newstate(kalloc, p);
	if (!p->L)
		return -1;
	/* stash the proc pointer where the kernel api finds it (self()).
	 * set before the thread is created so lua_newthread copies it into
	 * the coroutine's extra space too.
	 */
	*(struct kproc **)lua_getextraspace(p->L) = p;
	p->id = nextpid++;	/* unique forever; slots recycle, pids don't */
	luaL_openlibs(p->L);

	/* self port = right handle 0 */
	struct kport *port = port_new();

	if (!port || right_new(p, port, 1) != 0) {
		if (port)
			port->used = 0;	/* no rights were taken */
		lua_close(p->L);
		return -1;
	}

	/* register the los.* modules in package.preload so chunks pull in
	 * the layers they need with an explicit require -- no globals, no
	 * disk search. los.sys and los.efi are C openers; los.thread is the
	 * lua runtime, loaded from disk once and preloaded (not auto-run).
	 */
	lua_getglobal(p->L, "package");
	lua_getfield(p->L, -1, "preload");

	lua_pushcfunction(p->L, los_sys_open);
	lua_setfield(p->L, -2, "los.sys");

	lua_pushcfunction(p->L, luaopen_los_efi);
	lua_setfield(p->L, -2, "los.efi");

	/* los.platform.{cons,wire,power} are each registered ONLY for
	 * their one owning task -- not gated by a runtime check, simply
	 * absent from package.preload everywhere else, so there is no
	 * check to get wrong: the function isn't reachable to call.
	 */
	switch (priv) {
	case PRIV_CONS:
		lua_pushcfunction(p->L, luaopen_los_platform_cons);
		lua_setfield(p->L, -2, "los.platform.cons");
		break;
	case PRIV_WIRE:
		lua_pushcfunction(p->L, luaopen_los_platform_wire);
		lua_setfield(p->L, -2, "los.platform.wire");
		break;
	case PRIV_POWER:
		lua_pushcfunction(p->L, luaopen_los_platform_power);
		lua_setfield(p->L, -2, "los.platform.power");
		break;
	case PRIV_NET:
		lua_pushcfunction(p->L, luaopen_los_platform_net);
		lua_setfield(p->L, -2, "los.platform.net");
		break;
	}

	if (luaL_loadfile(p->L, "/lib/thread.lua") == LUA_OK) {
		lua_setfield(p->L, -2, "los.thread");
	} else {
		kputs("los.thread load error: ");
		kputs(lua_tostring(p->L, -1));
		kputs("\n");
		lua_pop(p->L, 1);
	}

	lua_pop(p->L, 2);	/* preload, package */

	/* ninep (lib/ninep.lua) is found via plain require("ninep") --
	 * LUA_PATH search, ordinary fopen() -- same as any other module.
	 * it used to need a preload workaround here because reading was
	 * disk-gated; now that read is ambient (see stdio.c's fopen),
	 * that workaround is gone and require() just works.
	 */

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
		right_drop(&p->rights[0]);
		lua_close(p->L);
		return -1;
	}

	/* the lua runtime (los.thread) is a preloaded module now, pulled in
	 * on demand by require("los.thread") -- no auto-run bootstrap.
	 */
	lua_sethook(p->co, preempt_hook, LUA_MASKCOUNT, p->reductions);
	p->mem_limit = mem_limit;
	p->status = READY;
	p->waiting = 0;
	nlive++;
	return p->id;
}

/* build and deliver an exit notification: {exit=pid, normal=bool,
 * reason=string?} to the watcher's self port.
 */
static void
notify_exit(struct kproc *watcher, int pid, const char *reason)
{
	struct wbuf w = { 0 };
	unsigned int npairs = reason ? 3 : 2;
	lua_Integer id = pid;

	if (wbyte(&w, 'B') || wput(&w, &npairs, 4))
		goto fail;

	unsigned int klen = 4;

	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "exit", 4) ||
	    wbyte(&w, 'I') || wput(&w, &id, sizeof id))
		goto fail;

	klen = 6;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "normal", 6) ||
	    wbyte(&w, reason ? 'F' : 'T'))
		goto fail;

	if (reason) {
		unsigned int rlen = strlen(reason);

		if (rlen > 200)
			rlen = 200;
		klen = 6;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "reason", 6) || wbyte(&w, 'S') ||
		    wput(&w, &rlen, 4) || wput(&w, reason, rlen))
			goto fail;
	}
	port_push(watcher->rights[0].port, w.p, w.len, 0, 0);
fail:
	free(w.p);
}

static void
proc_kill(struct kproc *p, const char *why)
{
	char reason[224];

	/* copy the reason out: it usually points into the lua state we
	 * are about to close
	 */
	if (why) {
		snprintf(reason, sizeof reason, "%s", why);

		char buf[256];

		snprintf(buf, sizeof buf, "proc %d died: %s\n", p->id,
		    reason);
		kputs(buf);
	}
	lua_close(p->L);
	p->status = DEAD;
	p->L = 0;
	p->co = 0;
	nlive--;

	/* release every right this proc held; ports lose refs, orphaned
	 * queues flush, unreferenced ports free
	 */
	for (int i = 0; i < MAXRIGHTS; i++)
		if (p->rights[i].used)
			right_drop(&p->rights[i]);

	/* erlang-style DOWN: tell the watchers */
	for (int i = 0; i < p->nwatch; i++) {
		struct kproc *w = find_proc(p->watchers[i]);

		if (w)
			notify_exit(w, p->id, why ? reason : 0);
	}
	p->nwatch = 0;
}

/* ---- serial pump (9p wire on com2) ---- */

extern void uart_init(void);
extern int uart_rx(void);
extern void uart_poll(void);	/* drain the hw fifo into the rx ring */

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
	port_push(serport, buf, 5 + n, 0, 0);
}

/* ---- net pump ---- */

/* safety net underneath net_event_notify: unconditionally nudge
 * netport every iteration (same ~1ms bound already accepted for
 * serial), so net.lua's pending tokens get rechecked even if the
 * tcp4 completion's own Event notify never actually gets dispatched
 * -- observed in practice (a real inbound connection completed
 * fully at the wire level, confirmed via packet capture, but the
 * notify-only path never woke the net task to notice). cheap: one
 * port_push, and checkpending() on the lua side is a no-op when
 * nothing's actually done yet.
 */
static void
pump_net(void)
{
	if (have_net && netport)
		port_push(netport, (const unsigned char *)"N", 1, 0, 0);
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
		port_push(kbdport, msg, sizeof msg, 0, 0);
	}
}

/* ---- kernel ---- */

int
kernel_init(void)
{
	uart_init();
	kbdport = port_new();
	serport = port_new();
	diskport = port_new();
	netport = port_new();
	if (!kbdport || !serport || !diskport || !netport)
		return -1;
	/* kernel refs: the pumps (and, for diskport/netport, the kernel
	 * itself) hold these ports forever
	 */
	kbdport->nrights++;
	serport->nrights++;
	diskport->nrights++;
	netport->nrights++;

	/* soft-fail: no NIC (real hardware, or qemu -net none) just means
	 * no net task gets spawned later, same as any other optional
	 * boot-time resource.
	 */
	have_net = (net_init() == 0);
	return 0;
}

/* spawn a privileged driver task and grant it whatever raw device
 * right it needs directly (handle 1, right after the universal
 * self-port at 0). returns its pid, or -1 with a boot warning; the
 * corresponding resource is simply unreachable for the rest of that
 * boot if its task fails to start.
 */
static int
spawn_driver(const char *path, const char *chunkname, int priv,
    struct kport *devport, int devrecv, const char *what)
{
	int pid = proc_new(path, 0, chunkname, 1, 0, 0, priv);

	if (pid < 0) {
		char buf[128];

		snprintf(buf, sizeof buf,
		    "warning: %s failed to start; %s is unavailable "
		    "this boot\n", chunkname + 1, what);
		kputs(buf);
		return -1;
	}
	if (devport) {
		struct kproc *p = find_proc(pid);

		if (p)
			right_new(p, devport, devrecv);
	}
	return pid;
}

/* spawn the boot payload (init.lua or an injected fw_cfg test buffer)
 * and hand it send-rights to cons/wire/power plus the disk capability
 * -- the full boot-level grant, same shape as the old KBD/SERIAL/CONIO
 * grant it replaces. ordinary sys.spawn children still get none of
 * this by default; only the boot payload (analogous to pid 1 on a
 * unix system) starts this privileged.
 */
static int
spawn_init(const char *code, size_t len, int is_file)
{
	int cons_pid = spawn_driver("/lib/cons.lua", "=cons", PRIV_CONS,
	    kbdport, 1, "console");
	int wire_pid = spawn_driver("/lib/wire.lua", "=wire", PRIV_WIRE,
	    serport, 1, "the 9p wire");
	int power_pid = spawn_driver("/lib/power.lua", "=power", PRIV_POWER,
	    0, 0, "reset/stall");
	/* no NIC (real hardware, or qemu -net none) is the normal case,
	 * not a boot failure -- don't even try spawning a task that could
	 * never listen/dial successfully.
	 */
	int net_pid = have_net ? spawn_driver("/lib/net.lua", "=net",
	    PRIV_NET, netport, 1, "networking") : -1;

	int pid = proc_new(code, len, "=init", is_file, 0, 0, PRIV_NONE);

	if (pid < 0)
		return pid;

	struct kproc *p = find_proc(pid);

	/* fixed handle numbers (1=CONS, 2=WIRE, 3=POWER, 4=DISK, 5=NET),
	 * granted by explicit index so a driver that failed to spawn just
	 * leaves a hole at its own number -- sys.send(sys.CONS,...) then
	 * fails with "bad right", cleanly, instead of some other
	 * capability silently sliding into the wrong handle.
	 */
	struct kproc *cons = cons_pid >= 0 ? find_proc(cons_pid) : 0;
	struct kproc *wire = wire_pid >= 0 ? find_proc(wire_pid) : 0;
	struct kproc *power = power_pid >= 0 ? find_proc(power_pid) : 0;
	struct kproc *net = net_pid >= 0 ? find_proc(net_pid) : 0;

	if (cons)
		right_new_at(p, 1, cons->rights[0].port, 0);
	if (wire)
		right_new_at(p, 2, wire->rights[0].port, 0);
	if (power)
		right_new_at(p, 3, power->rights[0].port, 0);
	if (diskport)
		right_new_at(p, 4, diskport, 0);
	if (net)
		right_new_at(p, 5, net->rights[0].port, 0);
	return pid;
}

int
kernel_spawn_file(const char *path)
{
	return spawn_init(path, 0, 1);
}

int
kernel_spawn_buffer(const char *code, size_t len)
{
	return spawn_init(code, len, 0);
}

void
kernel_run(void)
{
	EFI_EVENT tick = 0;
	EFI_EVENT waits[2 + MAXWAITEVENTS];
	UINTN index;

	/* periodic 1ms timer: idle becomes a real firmware sleep (hlt)
	 * instead of a hot stall-poll. the old "timer hangs the serial
	 * path" mystery was firmware console contention on com2, fixed
	 * by serial_takeover().
	 */
	if (BS->CreateEvent(EVT_TIMER, TPL_CALLBACK, 0, 0, &tick) !=
	    EFI_SUCCESS ||
	    BS->SetTimer(tick, TimerPeriodic, 10000) != EFI_SUCCESS)
		tick = 0;

	while (nlive > 0) {
		int ran = 0;

		pump_keyboard();
		pump_serial();
		pump_net();
		for (int i = 0; i < MAXPROCS; i++) {
			struct kproc *p = &procs[i];

			if (p->status != READY)
				continue;
			ran = 1;

			int nres = 0;

			current_proc = p;
			int rc = lua_resume(p->co, 0, 0, &nres);
			current_proc = 0;

			/* a proc can run a full hook window (200k insns)
			 * before yielding; drain the 16-byte fifo now so it
			 * can't overflow between serial pumps.
			 */
			uart_poll();
			if (rc == LUA_YIELD) {
				lua_pop(p->co, nres);
				continue;	/* READY or BLOCKED */
			}
			if (rc == LUA_OK)
				proc_kill(p, 0);
			else
				/* error object is on the stack; read it
				 * before proc_kill closes the state
				 */
				proc_kill(p, lua_tostring(p->co, -1));
		}
		if (!ran) {
			/* everyone blocked: sleep until key, tick, or any
			 * registered device completion (net.c's tcp4
			 * tokens). the tick bounds serial rx latency at ~1ms
			 * and, now, how promptly a fired net event gets
			 * noticed even if something raced registration.
			 */
			if (tick) {
				UINTN n = 0;

				waits[n++] = ST->ConIn->WaitForKey;
				waits[n++] = tick;
				for (int i = 0; i < nextra_wait_events; i++)
					waits[n++] = extra_wait_events[i];
				BS->WaitForEvent(n, waits, &index);
			} else
				BS->Stall(500);
		}
	}
}

/* disk gates write/append only (read is ambient, see stdio.c's
 * fopen): does whoever is currently resumed hold any right to
 * diskport? used from fopen, which has no lua_State at all --
 * liolib.c's io.open calls it as plain C, so current_proc is the
 * only way to learn who's asking.
 */
int
kernel_current_has_disk(void)
{
	if (!current_proc)
		return 0;
	for (int i = 0; i < MAXRIGHTS; i++)
		if (current_proc->rights[i].used &&
		    current_proc->rights[i].port == diskport)
			return 1;
	return 0;
}
