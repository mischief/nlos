/* the serializer: lua values to bytes and back, and the one place a
 * capability crosses from one proc into another. see docs/serialize.md
 * for the wire format and what may travel.
 */

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "buf.h"
#include "kernel.h"
#include "kproc.h"
#include "serialize.h"

/* a port index beyond 16 bits would alias onto a live port, and the
 * receive side's range check cannot catch it: the aliased value is in
 * range. fail the build rather than corrupt delivery.
 */
_Static_assert(MAXPORTS <= 65536, "port index is 16 bits in the serializer");

int
wput(struct wbuf *w, const void *src, size_t n)
{
	if (w->len + n > w->cap) {
		size_t need = w->len + n;

		/* MAXMSG bounds the message, not the growth policy:
		 * doubling may overshoot and get clamped, and only a
		 * message that does not fit is refused.
		 */
		if (need > MAXMSG)
			return -1;

		size_t ncap = w->cap ? w->cap * 2 : 256;

		while (ncap < need)
			ncap *= 2;
		if (ncap > MAXMSG)
			ncap = MAXMSG;
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

int
wbyte(struct wbuf *w, unsigned char c)
{
	return wput(w, &c, 1);
}

/* guess the serialized size at idx, for wreserve. a hint only: wput
 * grows whenever this comes up short, so being wrong costs a realloc
 * and never correctness. walks one level.
 */
size_t
sizehint(lua_State *L, int idx)
{
	size_t total = 16, n;

	idx = lua_absindex(L, idx);
	if (lua_type(L, idx) == LUA_TSTRING) {
		lua_tolstring(L, idx, &n);
		return n + 16;
	}
	if (lua_type(L, idx) != LUA_TTABLE)
		return 0;

	lua_pushnil(L);
	while (lua_next(L, idx)) {
		if (lua_type(L, -1) == LUA_TSTRING) {
			lua_tolstring(L, -1, &n);
			total += n + 8;
		} else
			total += 16;
		/* only where the key is already a string: converting a
		 * number key in place does not survive lua_next.
		 */
		if (lua_type(L, -2) == LUA_TSTRING) {
			lua_tolstring(L, -2, &n);
			total += n + 8;
		} else
			total += 16;
		lua_pop(L, 1);
	}
	return total;
}

/* take the hint. failure is not reported: the buffer is simply not
 * pre-sized, and wput grows it.
 */
void
wreserve(struct wbuf *w, size_t n)
{
	if (n < 256 || n > MAXMSG || w->cap >= n)
		return;

	unsigned char *p = realloc(w->p, n);

	if (p) {
		w->p = p;
		w->cap = n;
	}
}

int
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
		/* {__right = handle} copies a right: the sender's handle
		 * stays live and counts against MAXRIGHTS, so a caller
		 * minting one per request must close it.
		 */
		lua_getfield(L, idx, "__right");
		if (!lua_isnil(L, -1)) {
			/* refused, not shipped as data: shipping it would
			 * silently drop the capability it meant to send.
			 */
			if (!lua_isinteger(L, -1)) {
				lua_pop(L, 1);
				return -1;
			}
			struct right *r = right_get(sender,
			    lua_tointeger(L, -1));

			lua_pop(L, 1);
			if (!r || w->nrefs >= MAXMSGRIGHTS)
				return -1;
			unsigned short pi = r->port->idx;

			if (wbyte(w, 'R') || wput(w, &pi, sizeof pi))
				return -1;
			if (wbyte(w, (unsigned char)r->recv))
				return -1;
			/* count a receive right toward nrecv while in
			 * flight, or the sender closing its own copy takes
			 * nrecv to zero and flushes the queue.
			 */
			w->refrecv[w->nrefs] = (unsigned char)r->recv;
			w->refs[w->nrefs++] = pi;
			r->port->nrights++;
			if (r->recv)
				r->port->nrecv++;
			return 0;
		}
		lua_pop(L, 1);

		/* {__buf = b} gives the bytes away: the sender keeps an
		 * empty handle that raises on use. luabuf_borrow decides
		 * what may travel; the rest is refused, never copied.
		 */
		lua_getfield(L, idx, "__buf");
		if (!lua_isnil(L, -1)) {
			size_t n;
			void *handle;
			const char *s = luabuf_borrow(L, -1, &n, &handle);

			if (!s || w->bufs.n >= MAXMSGBUFS) {
				lua_pop(L, 1);
				return -1;
			}
			int i = w->bufs.n;

			if (wbyte(w, 'M') || wbyte(w, (unsigned char)i)) {
				lua_pop(L, 1);
				return -1;
			}
			w->bufs.p[i] = (void *)s;
			w->bufs.len[i] = n;
			w->bufown[i] = handle;
			w->bufs.n++;
			lua_pop(L, 1);
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
	case LUA_TUSERDATA: {
		/* a bare los.buf is copied and arrives as a string.
		 * {__buf = b} hands the bytes over instead.
		 */
		size_t n;
		const char *s = luabuf_bytes(L, idx, &n);
		unsigned int len;

		if (!s)
			return -1;
		len = (unsigned int)n;
		if (wbyte(w, 'S') || wput(w, &len, sizeof len))
			return -1;
		return wput(w, s, n);
	}
	default:
		return -1;	/* functions, other userdata: no travel */
	}
}

/* give back what a failed walk installed. */
void
minted_undo(struct kproc *p, struct minted *mt)
{
	if (mt->n == 0)
		return;

	ipclock_enter();
	for (int i = 0; i < mt->n; i++) {
		struct right *r = right_slot(p, mt->h[i]);

		if (r && r->used)
			right_drop(p, r);
		if (mt->h[i] < p->rhint)
			p->rhint = mt->h[i];
	}
	ipclock_leave();
	mt->n = 0;
}

int
deserialize(lua_State *L, const unsigned char *p, size_t len, size_t *off,
    struct msgbufs *bufs, struct kproc *receiver, int depth,
    struct minted *mt)
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
			int rc = deserialize(L, p, len, off, bufs, receiver,
			    depth + 1, mt);

			if (rc == 0)
				rc = deserialize(L, p, len, off, bufs, receiver,
				    depth + 1, mt);
			/* keep the reason: a nested right that could not
			 * be made is still a resource failure.
			 */
			if (rc)
				return rc;
			lua_settable(L, -3);
		}
		return 0;
	}
	case 'M': {
		/* a transferred buffer becomes the receiver's here.
		 * taking one clears the slot, so what remains at dispose
		 * time is what nobody received.
		 */
		if (*off >= len)
			return -1;
		int i = p[(*off)++];

		if (!bufs || i >= bufs->n || !bufs->p[i])
			return -1;
		if (!luabuf_give(L, bufs->p[i], bufs->len[i])) {
			/* a local limit, like a full rights table. the
			 * flag lets popfail name which limit it was.
			 */
			receiver->bufdenied = 1;
			return -2;
		}
		bufs->p[i] = 0;
		return 0;
	}
	case 'R': {
		if (*off + 3 > len)
			return -1;
		unsigned short pi;

		if (*off + sizeof pi > len)
			return -1;
		memcpy(&pi, p + *off, sizeof pi);
		*off += sizeof pi;

		unsigned char recv = p[(*off)++];

		if (pi >= MAXPORTS || !portv[pi])
			return -1;

		int h = right_new(receiver, portv[pi], recv);

		/* a full rights table is a local limit, not bad bytes */
		if (h < 0)
			return -2;	/* out of rights, not bad bytes */
		/* recorded before the table is built, because building it
		 * allocates and a failure there must give this back too.
		 * the bound cannot be exceeded -- serialize refuses to
		 * write more than MAXMSGRIGHTS -- but a message is bytes,
		 * so it is checked rather than trusted.
		 */
		if (mt->n >= MAXMSGRIGHTS)
			return -1;
		mt->h[mt->n++] = h;
		lua_createtable(L, 0, 1);
		lua_pushinteger(L, h);
		lua_setfield(L, -2, "__right");
		return 0;
	}
	default:
		return -1;
	}
}

