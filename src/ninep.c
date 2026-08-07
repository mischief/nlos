/* los.ninep: the 9P2000 field codec.
 *
 * lib/ninep.lua is the reference and stays reachable as ninep.pure;
 * this is the same codec in C, taken automatically when it is present.
 * test/boot/test_9p.lua and the p9 tests run whichever is selected, and
 * test_ninepc.lua checks the two against each other -- a differential
 * test, not a claim that either is right.
 *
 * Why it earns C: every field is a fixed-width little-endian integer or
 * a counted string, and lua reads those with string.unpack per field
 * and string.sub per payload, each of which allocates. Encoding is
 * worse -- a message is built by concatenating its parts, so a payload
 * is copied once into the body and again into the frame. That is the
 * shape lua is least good at, and there is no decision anywhere in it:
 * the layout is fixed by the protocol.
 *
 * It adds no authority and needs none: a pure function of the bytes it
 * is handed, like src/inet.c's checksum.
 *
 * Bounds are checked on every read, because the bytes come off a wire.
 * A message that runs out mid-field decodes to nil rather than raising:
 * a malformed message is an ordinary event for a server, and the lua
 * side already treats it that way.
 */

#include <stdint.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"

#include "buf.h"

/* message types, as lib/ninep.lua names them */
#define Tversion 100
#define Rversion 101
#define Tauth 102
#define Rauth 103
#define Tattach 104
#define Rattach 105
#define Rerror 107
#define Tflush 108
#define Rflush 109
#define Twalk 110
#define Rwalk 111
#define Topen 112
#define Ropen 113
#define Tcreate 114
#define Rcreate 115
#define Tread 116
#define Rread 117
#define Twrite 118
#define Rwrite 119
#define Tclunk 120
#define Rclunk 121
#define Tremove 122
#define Rremove 123
#define Tstat 124
#define Rstat 125
#define Twstat 126
#define Rwstat 127

#define HDRLEN 7		/* size[4] type[1] tag[2] */
#define QIDLEN 13		/* type[1] vers[4] path[8] */

/* ---- reading ---- */

struct rd {
	const unsigned char *p;
	size_t len, off;
	int bad;
};

static uint64_t
rdint(struct rd *r, int nbytes)
{
	uint64_t v = 0;
	int i;

	if (r->bad || r->off + (size_t)nbytes > r->len) {
		r->bad = 1;
		return 0;
	}
	for (i = nbytes - 1; i >= 0; i--)
		v = (v << 8) | r->p[r->off + i];
	r->off += (size_t)nbytes;
	return v;
}

/* a counted string, pushed. Nothing is pushed when the bytes run out,
 * so a caller must check bad before using the stack.
 */
static void
rdstr(lua_State *L, struct rd *r)
{
	uint64_t n = rdint(r, 2);

	if (r->bad || r->off + n > r->len) {
		r->bad = 1;
		return;
	}
	lua_pushlstring(L, (const char *)r->p + r->off, (size_t)n);
	r->off += (size_t)n;
}

static void
setint(lua_State *L, const char *k, uint64_t v)
{
	lua_pushinteger(L, (lua_Integer)v);
	lua_setfield(L, -2, k);
}

/* a qid as a table, left on the stack */
static void
rdqid(lua_State *L, struct rd *r)
{
	uint64_t t = rdint(r, 1), v = rdint(r, 4), p = rdint(r, 8);

	lua_createtable(L, 0, 3);
	setint(L, "type", t);
	setint(L, "vers", v);
	setint(L, "path", p);
}

/* the rest of the message as m.data, which is what Tread and Rread's
 * count[4] introduces.
 */
static void
rddata(lua_State *L, struct rd *r)
{
	uint64_t n = rdint(r, 4);

	if (r->bad || r->off + n > r->len) {
		r->bad = 1;
		return;
	}
	lua_pushlstring(L, (const char *)r->p + r->off, (size_t)n);
	lua_setfield(L, -2, "data");
	r->off += (size_t)n;
}

static int
np_decode(lua_State *L)
{
	size_t len;
	const char *s = luabuf_check(L, 1, &len);
	struct rd r = { (const unsigned char *)s, len, 0, 0 };
	uint64_t size, typ, tag;

	size = rdint(&r, 4);
	typ = rdint(&r, 1);
	tag = rdint(&r, 2);
	if (r.bad)
		return 0;		/* nil: not even a header */

	lua_createtable(L, 0, 8);
	setint(L, "type", typ);
	setint(L, "tag", tag);
	setint(L, "size", size);

	switch ((int)typ) {
	case Tversion:
	case Rversion:
		setint(L, "msize", rdint(&r, 4));
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "version");
		break;
	case Tauth:
		setint(L, "afid", rdint(&r, 4));
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "uname");
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "aname");
		break;
	case Tattach:
		setint(L, "fid", rdint(&r, 4));
		setint(L, "afid", rdint(&r, 4));
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "uname");
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "aname");
		break;
	case Tflush:
		setint(L, "oldtag", rdint(&r, 2));
		break;
	case Twalk: {
		uint64_t n;

		setint(L, "fid", rdint(&r, 4));
		setint(L, "newfid", rdint(&r, 4));
		n = rdint(&r, 2);
		lua_createtable(L, (int)(n > 16 ? 16 : n), 0);
		for (uint64_t i = 1; i <= n && !r.bad; i++) {
			rdstr(L, &r);
			if (r.bad)
				break;
			lua_rawseti(L, -2, (lua_Integer)i);
		}
		lua_setfield(L, -2, "wname");
		break;
	}
	case Rwalk: {
		uint64_t n = rdint(&r, 2);

		lua_createtable(L, (int)(n > 16 ? 16 : n), 0);
		for (uint64_t i = 1; i <= n && !r.bad; i++) {
			rdqid(L, &r);
			if (r.bad) {
				lua_pop(L, 1);
				break;
			}
			lua_rawseti(L, -2, (lua_Integer)i);
		}
		lua_setfield(L, -2, "wqid");
		break;
	}
	case Topen:
		setint(L, "fid", rdint(&r, 4));
		setint(L, "mode", rdint(&r, 1));
		break;
	case Tcreate:
		setint(L, "fid", rdint(&r, 4));
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "name");
		setint(L, "perm", rdint(&r, 4));
		setint(L, "mode", rdint(&r, 1));
		break;
	case Tread:
		setint(L, "fid", rdint(&r, 4));
		setint(L, "offset", rdint(&r, 8));
		setint(L, "count", rdint(&r, 4));
		break;
	case Twrite:
		setint(L, "fid", rdint(&r, 4));
		setint(L, "offset", rdint(&r, 8));
		rddata(L, &r);
		break;
	case Rread:
		rddata(L, &r);
		break;
	case Rwrite:
		setint(L, "count", rdint(&r, 4));
		break;
	case Tclunk:
	case Tremove:
	case Tstat:
	case Twstat:
		setint(L, "fid", rdint(&r, 4));
		break;
	case Rerror:
		rdstr(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "ename");
		break;
	case Rattach:
		rdqid(L, &r);
		if (!r.bad)
			lua_setfield(L, -2, "qid");
		else
			lua_pop(L, 1);
		break;
	case Ropen:
	case Rcreate:
		rdqid(L, &r);
		if (r.bad) {
			lua_pop(L, 1);
			break;
		}
		lua_setfield(L, -2, "qid");
		setint(L, "iounit", rdint(&r, 4));
		break;
	case Rclunk:
	case Rremove:
	case Rflush:
	case Rwstat:
		break;			/* empty body */
	case Rstat: {
		/* two wrappers: Rstat's own stat[n], and the leading
		 * size[2] every stat record carries. Both are stripped,
		 * which is the shape unpackstat wants.
		 */
		uint64_t n = rdint(&r, 2);

		if (r.bad || n < 2 || r.off + n > r.len) {
			r.bad = 1;
			break;
		}
		lua_pushlstring(L, (const char *)r.p + r.off + 2,
		    (size_t)n - 2);
		lua_setfield(L, -2, "statbytes");
		r.off += (size_t)n;
		break;
	}
	default:
		lua_pushboolean(L, 1);
		lua_setfield(L, -2, "unknown");
		break;
	}

	if (r.bad) {
		lua_pop(L, 1);
		return 0;		/* nil: it ran out mid-field */
	}
	return 1;
}

static int
np_unpackstat(lua_State *L)
{
	size_t len;
	const char *s = luabuf_check(L, 1, &len);
	struct rd r = { (const unsigned char *)s, len, 0, 0 };

	rdint(&r, 2);			/* type, kernel use */
	rdint(&r, 4);			/* dev, kernel use */

	lua_createtable(L, 0, 9);
	rdqid(L, &r);
	if (r.bad) {
		lua_pop(L, 2);
		return 0;
	}
	lua_setfield(L, -2, "qid");
	setint(L, "mode", rdint(&r, 4));
	setint(L, "atime", rdint(&r, 4));
	setint(L, "mtime", rdint(&r, 4));
	setint(L, "length", rdint(&r, 8));

	static const char *const names[] = { "name", "uid", "gid", "muid" };

	for (int i = 0; i < 4; i++) {
		rdstr(L, &r);
		if (r.bad) {
			lua_pop(L, 1);
			return 0;
		}
		lua_setfield(L, -2, names[i]);
	}
	return 1;
}

/* ---- writing ---- */

struct wr {
	unsigned char *p;
	size_t len;
};

static void
wrint(struct wr *w, uint64_t v, int nbytes)
{
	for (int i = 0; i < nbytes; i++)
		w->p[w->len++] = (unsigned char)(v >> (8 * i));
}

static void
wrbytes(struct wr *w, const char *s, size_t n)
{
	memcpy(w->p + w->len, s, n);
	w->len += n;
}

static void
wrstr(struct wr *w, const char *s, size_t n)
{
	wrint(w, n, 2);
	wrbytes(w, s, n);
}

/* how long a field is on the wire, for sizing the one buffer a message
 * is built in. A string is its bytes plus the count in front.
 */
static size_t
fieldlen(lua_State *L, int idx, const char *k, const char *dflt)
{
	size_t n;

	lua_getfield(L, idx, k);
	if (!lua_isstring(L, -1))
		n = strlen(dflt);	/* what strfield will write instead */
	else
		lua_tolstring(L, -1, &n);
	lua_pop(L, 1);
	return n + 2;
}

static const char *
strfield(lua_State *L, int idx, const char *k, const char *dflt, size_t *n)
{
	const char *s;

	lua_getfield(L, idx, k);
	s = lua_tolstring(L, -1, n);
	if (!s) {
		s = dflt;
		*n = strlen(dflt);
	}
	/* the value stays on the stack: popping it here would let the
	 * collector take the string this pointer names.
	 */
	return s;
}

static lua_Integer
intfield(lua_State *L, int idx, const char *k)
{
	lua_Integer v;

	lua_getfield(L, idx, k);
	v = lua_tointeger(L, -1);
	lua_pop(L, 1);
	return v;
}

static void
wrqid(lua_State *L, struct wr *w, int idx)
{
	lua_getfield(L, idx, "qid");

	int q = lua_gettop(L);

	wrint(w, (uint64_t)intfield(L, q, "type"), 1);
	wrint(w, (uint64_t)intfield(L, q, "vers"), 4);
	wrint(w, (uint64_t)intfield(L, q, "path"), 8);
	lua_pop(L, 1);
}

/* stat[n]: the record with its own size[2] in front, which is what
 * lib/ninep.lua's packstat returns.
 */
static int
np_packstat(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);

	size_t body = 2 + 4 + QIDLEN + 4 + 4 + 4 + 8;
	size_t nn, un, gn, mn;

	body += fieldlen(L, 1, "name", "");
	body += fieldlen(L, 1, "uid", "luaos");
	body += fieldlen(L, 1, "gid", "luaos");
	body += fieldlen(L, 1, "muid", "luaos");

	luaL_Buffer b;
	struct wr w = { (unsigned char *)luaL_buffinitsize(L, &b, body + 2), 0 };

	wrint(&w, body, 2);
	wrint(&w, 0, 2);		/* type, kernel use */
	wrint(&w, 0, 4);		/* dev, kernel use */
	wrqid(L, &w, 1);
	wrint(&w, (uint64_t)intfield(L, 1, "mode"), 4);
	wrint(&w, (uint64_t)intfield(L, 1, "atime"), 4);
	wrint(&w, (uint64_t)intfield(L, 1, "mtime"), 4);
	wrint(&w, (uint64_t)intfield(L, 1, "length"), 8);

	int top = lua_gettop(L);
	const char *name = strfield(L, 1, "name", "", &nn);
	const char *uid = strfield(L, 1, "uid", "luaos", &un);
	const char *gid = strfield(L, 1, "gid", "luaos", &gn);
	const char *muid = strfield(L, 1, "muid", "luaos", &mn);

	wrstr(&w, name, nn);
	wrstr(&w, uid, un);
	wrstr(&w, gid, gn);
	wrstr(&w, muid, mn);
	lua_settop(L, top);

	luaL_pushresultsize(&b, w.len);
	return 1;
}

/* the payload carriers, each built in one buffer.
 *
 * The payload is a string or a los.buf, and is copied once -- where
 * concatenating built the body around it and then the frame around
 * that.
 */
static int
np_rread(lua_State *L)
{
	lua_Integer tag = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luabuf_check(L, 2, &n);
	luaL_Buffer b;
	struct wr w = { (unsigned char *)luaL_buffinitsize(L, &b,
	    HDRLEN + 4 + n), 0 };

	wrint(&w, HDRLEN + 4 + n, 4);
	wrint(&w, Rread, 1);
	wrint(&w, (uint64_t)tag, 2);
	wrint(&w, n, 4);
	wrbytes(&w, data, n);
	luaL_pushresultsize(&b, w.len);
	return 1;
}

static int
np_twrite(lua_State *L)
{
	lua_Integer tag = luaL_checkinteger(L, 1);
	lua_Integer fid = luaL_checkinteger(L, 2);
	lua_Integer off = luaL_checkinteger(L, 3);
	size_t n;
	const char *data = luabuf_check(L, 4, &n);
	luaL_Buffer b;
	struct wr w = { (unsigned char *)luaL_buffinitsize(L, &b,
	    HDRLEN + 16 + n), 0 };

	wrint(&w, HDRLEN + 16 + n, 4);
	wrint(&w, Twrite, 1);
	wrint(&w, (uint64_t)tag, 2);
	wrint(&w, (uint64_t)fid, 4);
	wrint(&w, (uint64_t)off, 8);
	wrint(&w, n, 4);
	wrbytes(&w, data, n);
	luaL_pushresultsize(&b, w.len);
	return 1;
}

static int
np_tread(lua_State *L)
{
	lua_Integer tag = luaL_checkinteger(L, 1);
	lua_Integer fid = luaL_checkinteger(L, 2);
	lua_Integer off = luaL_checkinteger(L, 3);
	lua_Integer count = luaL_checkinteger(L, 4);
	unsigned char m[HDRLEN + 16];
	struct wr w = { m, 0 };

	wrint(&w, HDRLEN + 16, 4);
	wrint(&w, Tread, 1);
	wrint(&w, (uint64_t)tag, 2);
	wrint(&w, (uint64_t)fid, 4);
	wrint(&w, (uint64_t)off, 8);
	wrint(&w, (uint64_t)count, 4);
	lua_pushlstring(L, (const char *)m, w.len);
	return 1;
}

static int
np_twalk(lua_State *L)
{
	lua_Integer tag = luaL_checkinteger(L, 1);
	lua_Integer fid = luaL_checkinteger(L, 2);
	lua_Integer newfid = luaL_checkinteger(L, 3);
	size_t body = HDRLEN + 4 + 4 + 2;
	lua_Integer nname = 0;

	if (!lua_isnoneornil(L, 4)) {
		luaL_checktype(L, 4, LUA_TTABLE);
		nname = (lua_Integer)lua_rawlen(L, 4);
		for (lua_Integer i = 1; i <= nname; i++) {
			size_t n = 0;

			lua_rawgeti(L, 4, i);
			if (lua_isstring(L, -1))
				lua_tolstring(L, -1, &n);
			lua_pop(L, 1);
			body += n + 2;
		}
	}

	luaL_Buffer b;
	struct wr w = { (unsigned char *)luaL_buffinitsize(L, &b, body), 0 };

	wrint(&w, body, 4);
	wrint(&w, Twalk, 1);
	wrint(&w, (uint64_t)tag, 2);
	wrint(&w, (uint64_t)fid, 4);
	wrint(&w, (uint64_t)newfid, 4);
	wrint(&w, (uint64_t)nname, 2);
	for (lua_Integer i = 1; i <= nname; i++) {
		size_t n;
		const char *s;

		lua_rawgeti(L, 4, i);
		s = lua_tolstring(L, -1, &n);
		wrstr(&w, s ? s : "", s ? n : 0);
		lua_pop(L, 1);
	}
	luaL_pushresultsize(&b, w.len);
	return 1;
}

static const luaL_Reg nplib[] = {
	{ "decode", np_decode },
	{ "packstat", np_packstat },
	{ "unpackstat", np_unpackstat },
	{ "rread", np_rread },
	{ "twrite", np_twrite },
	{ "tread", np_tread },
	{ "twalk", np_twalk },
	{ NULL, NULL },
};

int luaopen_los_ninep(lua_State *L);

int
luaopen_los_ninep(lua_State *L)
{
	luaL_newlib(L, nplib);
	return 1;
}
