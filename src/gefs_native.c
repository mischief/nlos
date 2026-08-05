/* metrohash64_1, the one hot loop in gefs.
 *
 * lib/gefs/hash.lua is the reference and stays reachable as hash.pure;
 * this is the same function in C, selected automatically when it is
 * present. The spec suite checks the two against each other, so neither
 * is trusted alone -- a differential test, not a claim.
 *
 * Why it earns C when the rest of gefs does not: every block read
 * verifies a hash over the whole 16KiB block and every block written
 * computes one, so this is not on a hot path, it IS the hot path.
 * Measured with sys.trace on the served volume under load, 88% of the
 * gefs server's executed lines were in hash.lua -- 3610 of 4096 sampled,
 * against 2 in the transport it was supposedly waiting on.
 *
 * It adds no authority and needs none: a pure function of the string it
 * is handed, like src/native.c's ciphers and for the same reason. There
 * is nothing here to attenuate and no owner to be the only one.
 *
 * The arithmetic is 64-bit wrapping throughout, which is what lua 5.4
 * integers already are -- the port went the other way originally, and
 * the Lua reads as a transcription of C because it was one. Reads are
 * little-endian to match an unaligned load on amd64; a volume written
 * on a big-endian machine would checksum differently, and 9front's gefs
 * has the same property.
 */

#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#define K0 0xC83A91E1u
#define K1 0x8648DBDBu
#define K2 0x7BDEC03Bu
#define K3 0x2F5870A5u

static inline uint64_t
rotr64(uint64_t v, unsigned k)
{
	return (v >> k) | (v << (64 - k));
}

/* the reads are unaligned by construction -- a block is hashed from
 * wherever its buffer starts -- so they go through memcpy rather than a
 * cast. Every compiler this builds with turns that back into a single
 * load; -fno-strict-aliasing does not make the cast legal, it makes it
 * silently work.
 */
static inline uint64_t
ld64(const unsigned char *p)
{
	uint64_t v;

	memcpy(&v, p, sizeof v);
	return v;
}

static inline uint32_t
ld32(const unsigned char *p)
{
	uint32_t v;

	memcpy(&v, p, sizeof v);
	return v;
}

static inline uint16_t
ld16(const unsigned char *p)
{
	uint16_t v;

	memcpy(&v, p, sizeof v);
	return v;
}

static uint64_t
metro64(const unsigned char *s, size_t len, uint64_t seed)
{
	uint64_t h = (seed + K2) * K0 + len;
	const unsigned char *p = s;
	const unsigned char *e = s + len;

	if (len >= 32) {
		uint64_t v0 = h, v1 = h, v2 = h, v3 = h, t;

		do {
			v0 += ld64(p) * K0; v0 = rotr64(v0, 29) + v2;
			v1 += ld64(p + 8) * K1; v1 = rotr64(v1, 29) + v3;
			v2 += ld64(p + 16) * K2; v2 = rotr64(v2, 29) + v0;
			v3 += ld64(p + 24) * K3; v3 = rotr64(v3, 29) + v1;
			p += 32;
		} while (p <= e - 32);

		t = (v0 + v3) * K0 + v1; v2 ^= rotr64(t, 33) * K1;
		t = (v1 + v2) * K1 + v0; v3 ^= rotr64(t, 33) * K0;
		t = (v0 + v2) * K0 + v3; v0 ^= rotr64(t, 33) * K1;
		t = (v1 + v3) * K1 + v2; v1 ^= rotr64(t, 33) * K0;
		h += v0 ^ v1;
	}

	if (e - p >= 16) {
		uint64_t v0 = rotr64(h + ld64(p) * K0, 33) * K1;
		uint64_t v1 = rotr64(h + ld64(p + 8) * K1, 33) * K2;

		p += 16;
		v0 ^= rotr64(v0 * K0, 35) + v1;
		v1 ^= rotr64(v1 * K3, 35) + v0;
		h += v1;
	}
	if (e - p >= 8) {
		h += ld64(p) * K3;
		p += 8;
		h ^= rotr64(h, 33) * K1;
	}
	if (e - p >= 4) {
		h += (uint64_t)ld32(p) * K3;
		p += 4;
		h ^= rotr64(h, 15) * K1;
	}
	if (e - p >= 2) {
		h += (uint64_t)ld16(p) * K3;
		p += 2;
		h ^= rotr64(h, 13) * K1;
	}
	if (e - p >= 1) {
		h += (uint64_t)*p * K3;
		h ^= rotr64(h, 25) * K1;
	}

	h ^= rotr64(h, 33);
	h *= K0;
	h ^= rotr64(h, 33);
	return h;
}

/* metro64(s, seed, from, len) -- from is 1-based, as everywhere in lua,
 * and both it and len are optional exactly as in hash.lua. The result is
 * pushed as a lua integer, which is int64: same bits, and the Lua
 * version produces the same signed value by the same wrap.
 */
static int
gefs_metro64(lua_State *L)
{
	size_t slen;
	const char *s = luaL_checklstring(L, 1, &slen);
	uint64_t seed = (uint64_t)luaL_checkinteger(L, 2);
	lua_Integer from = luaL_optinteger(L, 3, 1);
	lua_Integer len;

	if (from < 1)
		return luaL_error(L, "metro64: from is 1-based");
	if ((size_t)(from - 1) > slen)
		return luaL_error(L, "metro64: from past the end");
	len = luaL_optinteger(L, 4, (lua_Integer)(slen - (size_t)(from - 1)));
	if (len < 0)
		return luaL_error(L, "metro64: negative length");
	if ((size_t)(from - 1) + (size_t)len > slen)
		return luaL_error(L, "metro64: run past the end");

	uint64_t h = metro64((const unsigned char *)s + (from - 1),
	    (size_t)len, seed);

	lua_pushinteger(L, (lua_Integer)h);
	return 1;
}

static const luaL_Reg gefslib[] = {
	{ "metro64", gefs_metro64 },
	{ NULL, NULL }
};

int luaopen_gefs_native(lua_State *L);

int
luaopen_gefs_native(lua_State *L)
{
	luaL_newlib(L, gefslib);
	return 1;
}
