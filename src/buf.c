/* los.buf: a mutable run of bytes.
 *
 * Lua strings are immutable, so every change to a byte is a new string:
 * updating one 32-byte directory entry in a 4096-byte sector costs
 * three allocations and 8KB copied, and a screen assembled a band at a
 * time costs a copy per band. That churn is what fills the heap with
 * short-lived objects and what leaves it fragmented afterwards.
 *
 * A buffer is one object that can be written in place. What it is for
 * is the places that already know how many bytes they have and where
 * they go: sectors, pixel bands, packets.
 *
 * ---- where the bytes live ----
 *
 * From the chunk source, not from the proc's lua heap. Two reasons, and
 * the second is the one that decides it:
 *
 *   A buffer is large and long-lived, which is the shape the small-class
 *   free lists in luaheap are not for.
 *
 *   A buffer is meant to travel. A lua heap belongs to one state -- one
 *   per proc when NCPU > 1 -- so bytes allocated there cannot be handed
 *   to another proc without copying them, which is the thing this
 *   exists to stop. Bytes from the chunk source are the kernel's, and
 *   handing them over is a change of owner.
 *
 * Travelling is not implemented here. What is implemented is the part
 * that cannot be retrofitted: the storage is already the kernel's, and
 * the handle already has an owner and can be emptied.
 *
 * ---- accounting ----
 *
 * Charged to the proc that allocates, against the same cap as its lua
 * memory, because a proc that can allocate outside its budget has no
 * budget. sys.stats() reports the machine's total and sys.meminfo() a
 * proc's share: memory that is not in the numbers is memory nobody
 * finds.
 *
 * ---- indices ----
 *
 * One-based and inclusive, exactly as string.sub and string.byte are.
 * A second convention in the same program is a bug generator.
 */

#include <stdint.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"

#include "buf.h"

/* the chunk source, which the kernel and the host tests each supply */
void *platform_chunk_alloc(size_t n);
void platform_chunk_free(void *p, size_t n);

#define BUFMT "los.buf"

struct luabuf {
	unsigned char	*p;	/* null once emptied */
	size_t		 len;
	int		 ro;	/* a view, or a buffer someone made read-only */
	int		 owned;	/* frees p; false for a view onto another */
};

static struct luabuf *
checkbuf(lua_State *L, int idx)
{
	struct luabuf *b = luaL_checkudata(L, idx, BUFMT);

	if (!b->p)
		luaL_error(L, "buffer has been given away");
	return b;
}

static struct luabuf *
checkwritable(lua_State *L, int idx)
{
	struct luabuf *b = checkbuf(L, idx);

	if (b->ro)
		luaL_error(L, "buffer is read-only");
	return b;
}

/* the bytes of a string or a buffer, so anything taking a payload takes
 * either without growing a second path. */
const char *
luabuf_bytes(lua_State *L, int idx, size_t *len)
{
	struct luabuf *b;

	if (lua_type(L, idx) == LUA_TSTRING)
		return lua_tolstring(L, idx, len);

	b = luaL_testudata(L, idx, BUFMT);
	if (!b)
		return 0;
	if (!b->p)
		luaL_error(L, "buffer has been given away");
	*len = b->len;
	return (const char *)b->p;
}

/* i and j as string.sub means them: one-based, inclusive, negative from
 * the end, clamped to the buffer. Returns the range as a 0-based offset
 * and a length. */
static void
range(lua_State *L, struct luabuf *b, int argi, size_t *off, size_t *n)
{
	lua_Integer i = luaL_optinteger(L, argi, 1);
	lua_Integer j = luaL_optinteger(L, argi + 1, -1);
	lua_Integer len = (lua_Integer)b->len;

	if (i < 0)
		i = len + i + 1;
	if (j < 0)
		j = len + j + 1;
	if (i < 1)
		i = 1;
	if (j > len)
		j = len;
	if (i > j) {
		*off = 0;
		*n = 0;
		return;
	}
	*off = (size_t)(i - 1);
	*n = (size_t)(j - i + 1);
}

static int
buf_new(lua_State *L)
{
	size_t n = (size_t)luaL_checkinteger(L, 1);
	int fill = (int)luaL_optinteger(L, 2, 0);
	struct luabuf *b;
	unsigned char *p;

	if (n == 0)
		return luaL_error(L, "a buffer of no bytes");
	if (!kbuf_charge(L, n))
		return luaL_error(L, "not enough memory for %d bytes", (int)n);

	p = platform_chunk_alloc(n);
	if (!p) {
		kbuf_uncharge(L, n);
		return luaL_error(L, "not enough memory for %d bytes", (int)n);
	}
	memset(p, fill & 0xff, n);

	b = lua_newuserdatauv(L, sizeof *b, 1);
	b->p = p;
	b->len = n;
	b->ro = 0;
	b->owned = 1;
	luaL_setmetatable(L, BUFMT);
	return 1;
}

static int
buf_gc(lua_State *L)
{
	struct luabuf *b = luaL_checkudata(L, 1, BUFMT);

	if (b->p && b->owned) {
		platform_chunk_free(b->p, b->len);
		kbuf_uncharge(L, b->len);
	}
	b->p = 0;
	return 0;
}

static int
buf_len(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);

	lua_pushinteger(L, (lua_Integer)b->len);
	return 1;
}

static int
buf_sub(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);
	size_t off, n;

	range(L, b, 2, &off, &n);
	lua_pushlstring(L, (const char *)b->p + off, n);
	return 1;
}

static int
buf_byte(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);
	size_t off, n, i;

	range(L, b, 2, &off, &n);
	if (n == 0)
		return 0;
	if (n > 250)
		return luaL_error(L, "byte: %d is too many at once", (int)n);
	luaL_checkstack(L, (int)n, "buffer bytes");
	for (i = 0; i < n; i++)
		lua_pushinteger(L, b->p[off + i]);
	return (int)n;
}

/* set(i, ...) -- bytes from i onwards, as string.byte's inverse */
static int
buf_set(lua_State *L)
{
	struct luabuf *b = checkwritable(L, 1);
	lua_Integer i = luaL_checkinteger(L, 2);
	int n = lua_gettop(L) - 2;
	int k;

	if (i < 1 || (size_t)(i - 1) + (size_t)n > b->len)
		return luaL_error(L, "set: outside the buffer");
	for (k = 0; k < n; k++)
		b->p[i - 1 + k] =
		    (unsigned char)(luaL_checkinteger(L, 3 + k) & 0xff);
	return 0;
}

/* copy(i, src [, from [, to]]) -- src's bytes into this buffer at i.
 * src is a string or another buffer; from and to select part of it, as
 * string.sub means them. */
static int
buf_copy(lua_State *L)
{
	struct luabuf *b = checkwritable(L, 1);
	lua_Integer i = luaL_checkinteger(L, 2);
	size_t slen;
	const char *s = luabuf_bytes(L, 3, &slen);
	lua_Integer from = luaL_optinteger(L, 4, 1);
	lua_Integer to = luaL_optinteger(L, 5, -1);

	if (!s)
		return luaL_error(L, "copy: a string or a buffer");
	if (from < 0)
		from = (lua_Integer)slen + from + 1;
	if (to < 0)
		to = (lua_Integer)slen + to + 1;
	if (from < 1)
		from = 1;
	if (to > (lua_Integer)slen)
		to = (lua_Integer)slen;
	if (from > to)
		return 0;

	size_t n = (size_t)(to - from + 1);

	if (i < 1 || (size_t)(i - 1) + n > b->len)
		return luaL_error(L, "copy: %d bytes at %d is outside the "
		    "buffer (%d)", (int)n, (int)i, (int)b->len);
	/* memmove: the source may be this same buffer */
	memmove(b->p + (i - 1), s + (from - 1), n);
	lua_pushinteger(L, (lua_Integer)n);
	return 1;
}

/* fill(byte [, i [, j]]) */
static int
buf_fill(lua_State *L)
{
	struct luabuf *b = checkwritable(L, 1);
	int v = (int)luaL_checkinteger(L, 2);
	size_t off, n;

	range(L, b, 3, &off, &n);
	memset(b->p + off, v & 0xff, n);
	return 0;
}

/* ---- fields ----
 *
 * The read side is why these exist rather than being a convenience.
 * string.unpack reads a field out of a string in place and allocates
 * nothing, so a sector held as a string costs nothing to read fields
 * from. A buffer without these would have to make a string per field to
 * hand to unpack, which is an allocation where there was none -- the
 * opposite of the point.
 *
 * Both byte orders are named, neither is the default. Little-endian is
 * FAT and 9P, big-endian is every packet header, and both are in this
 * tree: a default here would be a thing to remember at every call.
 *
 * Unsigned only. A signed field is rare in the formats here and would
 * be a second family of names for something a caller can do with one
 * subtraction.
 */
static uint64_t
getint(lua_State *L, int nbytes, int be)
{
	struct luabuf *b = checkbuf(L, 1);
	lua_Integer i = luaL_checkinteger(L, 2);
	uint64_t v = 0;
	int k;

	if (i < 1 || (size_t)(i - 1) + (size_t)nbytes > b->len)
		luaL_error(L, "%d bytes at %d is outside the buffer (%d)",
		    nbytes, (int)i, (int)b->len);
	for (k = 0; k < nbytes; k++) {
		unsigned char c = b->p[i - 1 + (be ? k : nbytes - 1 - k)];

		v = (v << 8) | c;
	}
	return v;
}

static void
setint(lua_State *L, int nbytes, int be)
{
	struct luabuf *b = checkwritable(L, 1);
	lua_Integer i = luaL_checkinteger(L, 2);
	uint64_t v = (uint64_t)luaL_checkinteger(L, 3);
	int k;

	if (i < 1 || (size_t)(i - 1) + (size_t)nbytes > b->len)
		luaL_error(L, "%d bytes at %d is outside the buffer (%d)",
		    nbytes, (int)i, (int)b->len);
	for (k = 0; k < nbytes; k++) {
		unsigned char c = (unsigned char)(v >> (8 * k));

		b->p[i - 1 + (be ? nbytes - 1 - k : k)] = c;
	}
}

#define GETTER(name, n, be)					\
	static int name(lua_State *L)				\
	{							\
		lua_pushinteger(L,				\
		    (lua_Integer)getint(L, (n), (be)));		\
		return 1;					\
	}

#define SETTER(name, n, be)					\
	static int name(lua_State *L)				\
	{							\
		setint(L, (n), (be));				\
		return 0;					\
	}

GETTER(buf_u8, 1, 0)
GETTER(buf_u16le, 2, 0)
GETTER(buf_u16be, 2, 1)
GETTER(buf_u32le, 4, 0)
GETTER(buf_u32be, 4, 1)
GETTER(buf_u64le, 8, 0)
GETTER(buf_u64be, 8, 1)

SETTER(buf_setu8, 1, 0)
SETTER(buf_setu16le, 2, 0)
SETTER(buf_setu16be, 2, 1)
SETTER(buf_setu32le, 4, 0)
SETTER(buf_setu32be, 4, 1)
SETTER(buf_setu64le, 8, 0)
SETTER(buf_setu64be, 8, 1)

/* view(i, j) -- part of this buffer, sharing its bytes.
 *
 * For handing a run of a large buffer to something that takes a payload
 * -- one band of a screen, one sector of a cluster read -- without
 * cutting a copy out of it first. A view of a read-only buffer is
 * read-only; a view of a writable one can be written, since it is the
 * same owner's memory either way.
 *
 * The view holds the buffer as a uservalue, so the bytes outlive it.
 */
static int
buf_view(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);
	size_t off, n;
	struct luabuf *v;

	range(L, b, 2, &off, &n);
	v = lua_newuserdatauv(L, sizeof *v, 1);
	v->p = b->p + off;
	v->len = n;
	v->ro = b->ro;
	v->owned = 0;
	luaL_setmetatable(L, BUFMT);

	/* the parent, not the grandparent: a view of a view keeps the
	 * view, which keeps what it came from.
	 */
	lua_pushvalue(L, 1);
	lua_setiuservalue(L, -2, 1);
	return 1;
}

/* a read-only view of the same bytes.
 *
 * What a refcount would be for, without the count: hand out a view and
 * the holder cannot write, whoever else holds what. The view keeps the
 * buffer alive through a uservalue, so the bytes outlive it.
 */
static int
buf_ro(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);
	struct luabuf *v = lua_newuserdatauv(L, sizeof *v, 1);

	v->p = b->p;
	v->len = b->len;
	v->ro = 1;
	v->owned = 0;
	luaL_setmetatable(L, BUFMT);

	lua_pushvalue(L, 1);
	lua_setiuservalue(L, -2, 1);
	return 1;
}

static int
buf_clone(lua_State *L)
{
	struct luabuf *b = checkbuf(L, 1);

	lua_pushcfunction(L, buf_new);
	lua_pushinteger(L, (lua_Integer)b->len);
	lua_call(L, 1, 1);

	struct luabuf *c = luaL_checkudata(L, -1, BUFMT);

	memcpy(c->p, b->p, b->len);
	return 1;
}

/* deliberately not the bytes: a buffer is the thing you have so that
 * the bytes are not copied, and a print() that copied them would undo
 * that silently. tostring says what it is; str() says the bytes.
 */
static int
buf_tostring(lua_State *L)
{
	struct luabuf *b = luaL_checkudata(L, 1, BUFMT);

	if (!b->p)
		lua_pushliteral(L, "buf(given away)");
	else
		lua_pushfstring(L, "buf(%d%s)", (int)b->len,
		    b->ro ? ", read-only" : "");
	return 1;
}

static const luaL_Reg bufmeth[] = {
	{ "len", buf_len },
	{ "sub", buf_sub },
	{ "str", buf_sub },
	{ "byte", buf_byte },
	{ "set", buf_set },
	{ "copy", buf_copy },
	{ "fill", buf_fill },
	{ "view", buf_view },
	{ "u8", buf_u8 },
	{ "u16le", buf_u16le },
	{ "u16be", buf_u16be },
	{ "u32le", buf_u32le },
	{ "u32be", buf_u32be },
	{ "u64le", buf_u64le },
	{ "u64be", buf_u64be },
	{ "setu8", buf_setu8 },
	{ "setu16le", buf_setu16le },
	{ "setu16be", buf_setu16be },
	{ "setu32le", buf_setu32le },
	{ "setu32be", buf_setu32be },
	{ "setu64le", buf_setu64le },
	{ "setu64be", buf_setu64be },
	{ "ro", buf_ro },
	{ "clone", buf_clone },
	{ NULL, NULL },
};

static const luaL_Reg buflib[] = {
	{ "new", buf_new },
	{ NULL, NULL },
};

int luaopen_los_buf(lua_State *L);

int
luaopen_los_buf(lua_State *L)
{
	luaL_newmetatable(L, BUFMT);
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");
	luaL_setfuncs(L, bufmeth, 0);
	lua_pushcfunction(L, buf_len);
	lua_setfield(L, -2, "__len");
	lua_pushcfunction(L, buf_gc);
	lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, buf_tostring);
	lua_setfield(L, -2, "__tostring");
	lua_pop(L, 1);

	luaL_newlib(L, buflib);
	return 1;
}

/* the bytes of a string or a buffer, raising if it is neither.
 *
 * For the C functions that take a payload -- a checksum, a crc, a hash.
 * A caller building a header in a buffer would otherwise have to cut a
 * string out of it to be summed, which is the copy the buffer exists to
 * avoid.
 */
const char *
luabuf_check(lua_State *L, int idx, size_t *len)
{
	const char *s = luabuf_bytes(L, idx, len);

	if (!s)
		luaL_error(L, "bad argument #%d (string or buffer expected)",
		    idx);
	return s;
}

/* the bytes of a writable buffer, for a C function that produces into
 * one. Null for a string, a read-only view, or anything else: what a
 * result is written into has to be something the caller may write.
 */
unsigned char *
luabuf_writable(lua_State *L, int idx, size_t *len)
{
	struct luabuf *b = luaL_testudata(L, idx, BUFMT);

	if (!b || b->ro)
		return 0;
	if (!b->p)
		luaL_error(L, "buffer has been given away");
	*len = b->len;
	return b->p;
}
