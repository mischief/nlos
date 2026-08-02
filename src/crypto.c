/*
 * ChaCha20 and Poly1305 in C, for where the pure-Lua versions are too
 * slow. Nothing else belongs here: measurement says the cipher is 100%
 * of the SSH packet layer's cost and the framing above it runs at
 * gigabytes per second, so this is the whole of the bulk-data problem.
 * The Lua implementations stay -- lib/crypto/{chacha20,poly1305}.lua --
 * as the reference, and as what runs if this is ever built out.
 *
 * Registered ambiently in package.preload, not granted to one task, and
 * the distinction AGENTS.md draws is what decides it: authority is an
 * ARGUMENT here, not the function. chacha20_xor(key, ...) does nothing
 * for a caller that does not already hold the key, so there is nothing
 * to attenuate and nothing to escalate -- unlike los.platform.rng next
 * door, where the raw draw IS the capability and one owner is the whole
 * protection.
 *
 * This was written for a hosted build and moved here unchanged, which is
 * the point of the rules it was written to. lua-os cannot dlopen (there
 * is no LUA_CPATH), so the only real difference is that it is compiled
 * in and preloaded rather than loaded from a .so.
 *
 * The rules, because lua-os compiles with -nostdinc and links neither a
 * hosted libc nor libgcc:
 *
 *   - Only <stddef.h> and <stdint.h>, both of which a freestanding
 *     compiler provides. No string.h, no stdlib.h, no stdio.h.
 *   - No libc calls at all, not even memcpy: byte loops instead, which
 *     the compiler is free to recognise.
 *   - No 64-bit division or modulo, which is what would pull in libgcc's
 *     __udivdi3 on a target that lacks the instruction. Only 64-bit
 *     multiply, add and shift, all native on x86_64, aarch64 and
 *     riscv64.
 *   - No unaligned loads and no endian assumption: every 32-bit word is
 *     assembled from and written back as bytes, by u32le/p32le. There is
 *     no #ifdef on byte order anywhere here, and there was: a
 *     little-endian fast path that copied the keystream block in one go
 *     measured 4% and had to be correct on three architectures to earn
 *     it. Plan 9 gets this right with plain get/put functions and so can
 *     we.
 *   - No static mutable state. Every function keeps its state on the
 *     stack, so this is reentrant and safe to call from several Lua
 *     states at once, which is how lua-os would use it.
 *   - No floating point.
 *
 * The Lua binding is the only part that is not freestanding, and it is
 * confined to the bottom of the file.
 */

#include <stddef.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* byte order helpers                                                   */

static uint32_t
u32le(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void
p32le(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v);
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

/* ------------------------------------------------------------------ */
/* ChaCha20, RFC 8439                                                   */

#define ROTL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

#define QR(a, b, c, d) do {                 \
	a += b; d ^= a; d = ROTL32(d, 16);  \
	c += d; b ^= c; b = ROTL32(b, 12);  \
	a += b; d ^= a; d = ROTL32(d, 8);   \
	c += d; b ^= c; b = ROTL32(b, 7);   \
} while (0)

static void
chacha20_block(uint8_t out[64], const uint8_t key[32], uint32_t counter,
    const uint8_t nonce[12])
{
	uint32_t s[16], x[16];
	int i;

	s[0] = 0x61707865; s[1] = 0x3320646e;
	s[2] = 0x79622d32; s[3] = 0x6b206574;
	for (i = 0; i < 8; i++)
		s[4 + i] = u32le(key + 4 * i);
	s[12] = counter;
	for (i = 0; i < 3; i++)
		s[13 + i] = u32le(nonce + 4 * i);

	for (i = 0; i < 16; i++)
		x[i] = s[i];

	for (i = 0; i < 10; i++) {
		QR(x[0], x[4], x[8], x[12]);
		QR(x[1], x[5], x[9], x[13]);
		QR(x[2], x[6], x[10], x[14]);
		QR(x[3], x[7], x[11], x[15]);
		QR(x[0], x[5], x[10], x[15]);
		QR(x[1], x[6], x[11], x[12]);
		QR(x[2], x[7], x[8], x[13]);
		QR(x[3], x[4], x[9], x[14]);
	}

	for (i = 0; i < 16; i++)
		p32le(out + 4 * i, x[i] + s[i]);
}

static void
chacha20_xor(uint8_t *restrict out, const uint8_t *restrict in, size_t len,
    const uint8_t key[32], uint32_t counter, const uint8_t nonce[12])
{
	uint8_t ks[64];
	size_t off, i, n;

	for (off = 0; off < len; off += 64) {
		chacha20_block(ks, key, counter, nonce);
		counter++;			/* wraps at 2^32, as it must */

		n = len - off;
		if (n > 64)
			n = 64;

		/*
		 * Eight bytes at a time where there is room. The two
		 * loads and the store are constant-size __builtin_memcpy,
		 * which the compiler folds into single (possibly
		 * unaligned) instructions -- so this needs no alignment
		 * guarantee from the caller and no libc. Endianness cannot
		 * matter: XOR is bytewise, and whatever order the bytes
		 * were loaded in they are stored back the same way.
		 */
		for (i = 0; i + 8 <= n; i += 8) {
			uint64_t a, b;

			__builtin_memcpy(&a, in + off + i, 8);
			__builtin_memcpy(&b, ks + i, 8);
			a ^= b;
			__builtin_memcpy(out + off + i, &a, 8);
		}
		for (; i < n; i++)
			out[off + i] = (uint8_t)(in[off + i] ^ ks[i]);
	}
}

/* ------------------------------------------------------------------ */
/* Poly1305, RFC 8439, following poly1305-donna-32                      */

struct poly1305 {
	uint32_t r[5];
	uint32_t h[5];
	uint32_t pad[4];
	uint8_t buf[16];
	size_t buflen;
};

static void
poly1305_init(struct poly1305 *st, const uint8_t key[32])
{
	uint32_t t0 = u32le(key + 0);
	uint32_t t1 = u32le(key + 4);
	uint32_t t2 = u32le(key + 8);
	uint32_t t3 = u32le(key + 12);
	int i;

	st->r[0] = t0 & 0x3ffffff;
	st->r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03;
	st->r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff;
	st->r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff;
	st->r[4] = (t3 >> 8) & 0x00fffff;

	for (i = 0; i < 5; i++)
		st->h[i] = 0;
	for (i = 0; i < 4; i++)
		st->pad[i] = u32le(key + 16 + 4 * i);

	st->buflen = 0;
}

/*
 * One 16-byte block. `hibit` is 1<<24 for a full block and 0 for the
 * final short one, which carries its own 0x01 terminator instead.
 *
 * The limb choice is what keeps this portable: 26-bit limbs make each
 * product fit in 52 bits and each accumulated column in about 57, so
 * everything stays inside uint64_t with no 128-bit type and no compiler
 * extension.
 */
static void
poly1305_block(struct poly1305 *st, const uint8_t m[16], uint32_t hibit)
{
	uint32_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2];
	uint32_t r3 = st->r[3], r4 = st->r[4];
	uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
	uint32_t h0, h1, h2, h3, h4;
	uint64_t d0, d1, d2, d3, d4;
	uint32_t c;

	uint32_t t0 = u32le(m + 0);
	uint32_t t1 = u32le(m + 4);
	uint32_t t2 = u32le(m + 8);
	uint32_t t3 = u32le(m + 12);

	h0 = st->h[0] + (t0 & 0x3ffffff);
	h1 = st->h[1] + (((t0 >> 26) | (t1 << 6)) & 0x3ffffff);
	h2 = st->h[2] + (((t1 >> 20) | (t2 << 12)) & 0x3ffffff);
	h3 = st->h[3] + (((t2 >> 14) | (t3 << 18)) & 0x3ffffff);
	h4 = st->h[4] + ((t3 >> 8) | hibit);

	d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 +
	     (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
	d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 +
	     (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
	d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 +
	     (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
	d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 +
	     (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
	d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 +
	     (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

	c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
	d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
	d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
	d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
	d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
	h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
	h1 += c;

	st->h[0] = h0; st->h[1] = h1; st->h[2] = h2;
	st->h[3] = h3; st->h[4] = h4;
}

static void
poly1305_update(struct poly1305 *restrict st, const uint8_t *restrict m,
    size_t len)
{
	size_t i;

	if (st->buflen > 0) {
		size_t want = 16 - st->buflen;
		size_t take = len < want ? len : want;

		for (i = 0; i < take; i++)
			st->buf[st->buflen + i] = m[i];
		st->buflen += take;
		m += take;
		len -= take;

		if (st->buflen == 16) {
			poly1305_block(st, st->buf, (uint32_t)1 << 24);
			st->buflen = 0;
		}
	}

	while (len >= 16) {
		poly1305_block(st, m, (uint32_t)1 << 24);
		m += 16;
		len -= 16;
	}

	/* append, rather than overwrite from zero. An update whose bytes
	 * all land inside a partial buffer without filling it leaves
	 * buflen > 0 and len == 0 here, and starting the copy at index 0
	 * would set buflen back to 0 and discard what was already
	 * buffered. Either buflen is 0 or len is, so this stays within
	 * the 16-byte buffer.
	 */
	for (i = 0; i < len; i++)
		st->buf[st->buflen + i] = m[i];
	st->buflen += len;
}

static void
poly1305_finish(struct poly1305 *st, uint8_t tag[16])
{
	uint32_t h0, h1, h2, h3, h4;
	uint32_t g0, g1, g2, g3, g4;
	uint32_t c, mask, nmask;
	uint64_t f;
	size_t i;

	if (st->buflen > 0) {
		st->buf[st->buflen] = 1;
		for (i = st->buflen + 1; i < 16; i++)
			st->buf[i] = 0;
		poly1305_block(st, st->buf, 0);
	}

	h0 = st->h[0]; h1 = st->h[1]; h2 = st->h[2];
	h3 = st->h[3]; h4 = st->h[4];

	c = h1 >> 26; h1 &= 0x3ffffff;
	h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
	h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
	h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
	h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
	h1 += c;

	/*
	 * h + -p, kept branch-free: whether the subtraction borrowed
	 * decides which of the two results is the answer, and that must
	 * not be a branch on secret state.
	 */
	g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
	g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
	g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
	g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
	g4 = h4 + c - ((uint32_t)1 << 26);

	mask = (g4 >> 31) - 1;		/* 0 on borrow, all ones otherwise */
	nmask = ~mask;
	h0 = (h0 & nmask) | (g0 & mask);
	h1 = (h1 & nmask) | (g1 & mask);
	h2 = (h2 & nmask) | (g2 & mask);
	h3 = (h3 & nmask) | (g3 & mask);
	h4 = (h4 & nmask) | (g4 & mask);

	h0 = (h0 | (h1 << 26));
	h1 = ((h1 >> 6) | (h2 << 20));
	h2 = ((h2 >> 12) | (h3 << 14));
	h3 = ((h3 >> 18) | (h4 << 8));

	f = (uint64_t)h0 + st->pad[0]; h0 = (uint32_t)f;
	f = (uint64_t)h1 + st->pad[1] + (f >> 32); h1 = (uint32_t)f;
	f = (uint64_t)h2 + st->pad[2] + (f >> 32); h2 = (uint32_t)f;
	f = (uint64_t)h3 + st->pad[3] + (f >> 32); h3 = (uint32_t)f;

	p32le(tag + 0, h0);
	p32le(tag + 4, h1);
	p32le(tag + 8, h2);
	p32le(tag + 12, h3);

	/* Wipe: the accumulator is as good as the key for forging. */
	for (i = 0; i < 5; i++) {
		st->r[i] = 0;
		st->h[i] = 0;
	}
	for (i = 0; i < 4; i++)
		st->pad[i] = 0;
}

/* ------------------------------------------------------------------ */
/* Lua binding. Everything above this line is freestanding.             */

#include "lua.h"
#include "lauxlib.h"

static const uint8_t *
checkbytes(lua_State *L, int idx, size_t want, const char *what)
{
	size_t len;
	const char *s = luaL_checklstring(L, idx, &len);

	if (len != want)
		luaL_error(L, "%s must be %d bytes, got %d", what,
		    (int)want, (int)len);
	return (const uint8_t *)s;
}

/* chacha20_block(key, counter, nonce) -> 64 bytes */
static int
l_chacha20_block(lua_State *L)
{
	const uint8_t *key = checkbytes(L, 1, 32, "chacha20 key");
	uint32_t counter = (uint32_t)luaL_checkinteger(L, 2);
	const uint8_t *nonce = checkbytes(L, 3, 12, "chacha20 nonce");
	uint8_t out[64];

	chacha20_block(out, key, counter, nonce);
	lua_pushlstring(L, (const char *)out, sizeof(out));
	return 1;
}

/* chacha20_xor(key, counter, nonce, data) -> data */
static int
l_chacha20_xor(lua_State *L)
{
	const uint8_t *key = checkbytes(L, 1, 32, "chacha20 key");
	uint32_t counter = (uint32_t)luaL_checkinteger(L, 2);
	const uint8_t *nonce = checkbytes(L, 3, 12, "chacha20 nonce");
	size_t len;
	const char *in = luaL_checklstring(L, 4, &len);
	luaL_Buffer b;
	char *out;

	if (len == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	out = luaL_buffinitsize(L, &b, len);
	chacha20_xor((uint8_t *)out, (const uint8_t *)in, len, key, counter,
	    nonce);
	luaL_pushresultsize(&b, len);
	return 1;
}

/* poly1305_auth(key, msg) -> 16 bytes */
static int
l_poly1305_auth(lua_State *L)
{
	const uint8_t *key = checkbytes(L, 1, 32, "poly1305 key");
	size_t len;
	const char *m = luaL_checklstring(L, 2, &len);
	struct poly1305 st;
	uint8_t tag[16];

	poly1305_init(&st, key);
	poly1305_update(&st, (const uint8_t *)m, len);
	poly1305_finish(&st, tag);

	lua_pushlstring(L, (const char *)tag, sizeof(tag));
	return 1;
}

/* Declared before the definitions because lua-os builds with
 * -Wmissing-prototypes and these are the only symbols here with
 * external linkage.
 */
int luaopen_crypto_chacha20(lua_State *L);
int luaopen_crypto_poly1305(lua_State *L);

/* The module names and the function names are the Lua implementations',
 * deliberately: lib/ssh/packet.lua and lib/crypto/drbg.lua require
 * "crypto.chacha20" and call .xor/.block, and they should not have to
 * know which language answered. The host tree (~/code/lua/ssh) keeps
 * both implementations behind this same interface and runs the RFC 8439
 * vectors against each, which is where a disagreement would be caught.
 */
static const luaL_Reg chachalib[] = {
	{ "block", l_chacha20_block },
	{ "xor", l_chacha20_xor },
	{ NULL, NULL }
};

static const luaL_Reg polylib[] = {
	{ "auth", l_poly1305_auth },
	{ NULL, NULL }
};

int
luaopen_crypto_chacha20(lua_State *L)
{
	luaL_newlib(L, chachalib);
	return 1;
}

int
luaopen_crypto_poly1305(lua_State *L)
{
	luaL_newlib(L, polylib);
	return 1;
}
