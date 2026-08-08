/*
 * ChaCha20, Poly1305 and AES in C, for where the pure-Lua versions are
 * too slow. Nothing arrives here without a measurement behind it: the
 * cipher is 100% of the SSH packet layer's cost and the framing above it
 * runs at gigabytes per second, and AES followed because a QUIC endpoint
 * cannot avoid AES-128-GCM for Initial packets however few suites it
 * offers -- see bench/quic.lua and the note above the AES section.
 *
 * Written to be dropped into a freestanding build. The rules it keeps,
 * because lua-os compiles with -nostdinc and links neither a hosted libc
 * nor libgcc:
 *
 *   - Only <stddef.h> and <stdint.h>, both of which a freestanding
 *     compiler provides. No string.h, no stdlib.h, no stdio.h.
 *   - No libc calls at all, not even memcpy: byte loops instead, which
 *     the compiler is free to recognise.
 *   - No 64-bit division or modulo, which is what would pull in libgcc's
 *     __udivdi3 on a target that lacks the instruction. Only 64-bit
 *     multiply, add and shift.
 *   - No 64-bit multiply of two 64-bit values. Every product here is
 *     32x32->64, which x86_64, aarch64 and riscv64 do in one
 *     instruction and which rv32im and Xtensa LX7 do in two, mul plus
 *     mulhu and mull plus mulsh. A full 64x64 multiply on those 32-bit
 *     targets is three multiplies and a shift-add, and the field
 *     arithmetic does enough of them for that to be the difference
 *     between fast and unusable.
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
 * Nothing here knows about Lua. The binding lives in native_glue.c,
 * which includes this file.
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
/* SHA-256 and SHA-512, FIPS 180-4: the compression functions only      */

/*
 * Not for SSH or QUIC, where hashing is handshake-rate and invisible
 * next to a Montgomery ladder. This is for hashing files: 3.5 MB/s in
 * Lua means half a minute of CPU to check a 100 MB transfer, and that is
 * a thing lua-os will want to do over 9P.
 *
 * The interface is a whole run of blocks at a time, not one block:
 * padding, buffering and the length field stay in ssh/crypto/hashstate.
 * lua, which is where the off-by-one lives and where it is already
 * tested. A per-block crossing would spend more in the Lua call than in
 * the compression.
 *
 * The state is carried as its big-endian encoding -- 32 bytes for
 * SHA-256, 64 for SHA-512 -- rather than as a table of integers, so the
 * boundary is one string in and one string out and there is no table
 * indexing on the hot path.
 */

#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define ROTR64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

static uint32_t
u32be(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void
p32be(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)(v);
}

static uint64_t
u64be(const uint8_t *p)
{
	return ((uint64_t)u32be(p) << 32) | (uint64_t)u32be(p + 4);
}

static void
p64be(uint8_t *p, uint64_t v)
{
	p32be(p, (uint32_t)(v >> 32));
	p32be(p + 4, (uint32_t)v);
}

static const uint32_t SHA256_K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static void
sha256_blocks(uint8_t state[32], const uint8_t *p, size_t nblocks)
{
	uint32_t h[8], w[64], a, b, c, d, e, f, g, hh, t1, t2, s0, s1;
	size_t n;
	int i;

	for (i = 0; i < 8; i++)
		h[i] = u32be(state + 4 * i);

	for (n = 0; n < nblocks; n++, p += 64) {
		for (i = 0; i < 16; i++)
			w[i] = u32be(p + 4 * i);
		for (i = 16; i < 64; i++) {
			s0 = ROTR32(w[i - 15], 7) ^ ROTR32(w[i - 15], 18) ^
			     (w[i - 15] >> 3);
			s1 = ROTR32(w[i - 2], 17) ^ ROTR32(w[i - 2], 19) ^
			     (w[i - 2] >> 10);
			w[i] = w[i - 16] + s0 + w[i - 7] + s1;
		}

		a = h[0]; b = h[1]; c = h[2]; d = h[3];
		e = h[4]; f = h[5]; g = h[6]; hh = h[7];

		for (i = 0; i < 64; i++) {
			s1 = ROTR32(e, 6) ^ ROTR32(e, 11) ^ ROTR32(e, 25);
			t1 = hh + s1 + ((e & f) ^ (~e & g)) + SHA256_K[i] + w[i];
			s0 = ROTR32(a, 2) ^ ROTR32(a, 13) ^ ROTR32(a, 22);
			t2 = s0 + ((a & b) ^ (a & c) ^ (b & c));
			hh = g; g = f; f = e; e = d + t1;
			d = c; c = b; b = a; a = t1 + t2;
		}

		h[0] += a; h[1] += b; h[2] += c; h[3] += d;
		h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
	}

	for (i = 0; i < 8; i++)
		p32be(state + 4 * i, h[i]);
}

static const uint64_t SHA512_K[80] = {
	0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL,
	0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
	0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
	0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
	0xd807aa98a3030242ULL, 0x12835b0145706fbeULL,
	0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
	0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL,
	0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
	0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
	0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
	0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL,
	0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
	0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL,
	0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
	0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
	0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
	0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL,
	0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
	0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL,
	0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
	0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
	0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
	0xd192e819d6ef5218ULL, 0xd69906245565a910ULL,
	0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
	0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL,
	0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
	0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
	0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
	0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL,
	0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
	0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL,
	0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
	0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
	0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
	0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL,
	0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
	0x28db77f523047d84ULL, 0x32caab7b40c72493ULL,
	0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
	0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
	0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL
};

static void
sha512_blocks(uint8_t state[64], const uint8_t *p, size_t nblocks)
{
	uint64_t h[8], w[80], a, b, c, d, e, f, g, hh, t1, t2, s0, s1;
	size_t n;
	int i;

	for (i = 0; i < 8; i++)
		h[i] = u64be(state + 8 * i);

	for (n = 0; n < nblocks; n++, p += 128) {
		for (i = 0; i < 16; i++)
			w[i] = u64be(p + 8 * i);
		for (i = 16; i < 80; i++) {
			s0 = ROTR64(w[i - 15], 1) ^ ROTR64(w[i - 15], 8) ^
			     (w[i - 15] >> 7);
			s1 = ROTR64(w[i - 2], 19) ^ ROTR64(w[i - 2], 61) ^
			     (w[i - 2] >> 6);
			w[i] = w[i - 16] + s0 + w[i - 7] + s1;
		}

		a = h[0]; b = h[1]; c = h[2]; d = h[3];
		e = h[4]; f = h[5]; g = h[6]; hh = h[7];

		for (i = 0; i < 80; i++) {
			s1 = ROTR64(e, 14) ^ ROTR64(e, 18) ^ ROTR64(e, 41);
			t1 = hh + s1 + ((e & f) ^ (~e & g)) + SHA512_K[i] + w[i];
			s0 = ROTR64(a, 28) ^ ROTR64(a, 34) ^ ROTR64(a, 39);
			t2 = s0 + ((a & b) ^ (a & c) ^ (b & c));
			hh = g; g = f; f = e; e = d + t1;
			d = c; c = b; b = a; a = t1 + t2;
		}

		h[0] += a; h[1] += b; h[2] += c; h[3] += d;
		h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
	}

	for (i = 0; i < 8; i++)
		p64be(state + 8 * i, h[i]);
}

/* ------------------------------------------------------------------ */
/* Keccak-f[1600] and the sponge, FIPS 202                              */

/*
 * SHA3-256, SHA3-512, SHAKE128 and SHAKE256 are one sponge that differs
 * only in its rate and its domain separator, so both are arguments here
 * and there is one absorb and one squeeze.
 *
 * ML-KEM is the heavy caller: SHAKE128 expands the matrix, SHAKE256 is
 * the noise PRF, and the two SHA-3 hashes bind the ciphertext.
 *
 * The permutation is xor, and-not, or and shift on 64-bit lanes. There
 * is no multiply and no divide, so nothing here can reach for libgcc's
 * __muldi3 or __udivdi3 on a 32-bit target.
 *
 * Rho and pi are written out one lane at a time with literal rotation
 * offsets rather than looped over a table of them. That is what keeps
 * the shift counts constant: a 64-bit shift by a run-time value lowers
 * to __ashldi3 and __lshrdi3 on riscv32 and xtensa, which a freestanding
 * link does not have. ssh/crypto/keccak.lua generates the same offsets
 * from the (x,y) walk of FIPS 202 3.2.2 and exports them, and the spec
 * suite checks these against those.
 *
 * The state crosses the Lua boundary as its 200-byte little-endian lane
 * encoding, so a caller can hold a sponge between calls -- which is what
 * ML-KEM's rejection sampling needs, since it cannot know in advance how
 * much SHAKE128 output it will use.
 */

static uint64_t
u64le(const uint8_t *p)
{
	return (uint64_t)u32le(p) | ((uint64_t)u32le(p + 4) << 32);
}

static void
p64le(uint8_t *p, uint64_t v)
{
	p32le(p, (uint32_t)v);
	p32le(p + 4, (uint32_t)(v >> 32));
}

/* The LFSR of FIPS 202 3.2.5, evaluated. */
static const uint64_t KECCAK_RC[24] = {
	0x0000000000000001ull, 0x0000000000008082ull,
	0x800000000000808aull, 0x8000000080008000ull,
	0x000000000000808bull, 0x0000000080000001ull,
	0x8000000080008081ull, 0x8000000000008009ull,
	0x000000000000008aull, 0x0000000000000088ull,
	0x0000000080008009ull, 0x000000008000000aull,
	0x000000008000808bull, 0x800000000000008bull,
	0x8000000000008089ull, 0x8000000000008003ull,
	0x8000000000008002ull, 0x8000000000000080ull,
	0x000000000000800aull, 0x800000008000000aull,
	0x8000000080008081ull, 0x8000000000008080ull,
	0x0000000080000001ull, 0x8000000080008008ull
};

#define ROL(x, n) (((x) << (n)) | ((x) >> (64 - (n))))

static void
keccakf1600(uint64_t s[25])
{
	uint64_t b[25];
	uint64_t c0, c1, c2, c3, c4, d0, d1, d2, d3, d4;
	int r;

	for (r = 0; r < 24; r++) {
		/* theta */
		c0 = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
		c1 = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
		c2 = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
		c3 = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
		c4 = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];

		d0 = c4 ^ ROL(c1, 1);
		d1 = c0 ^ ROL(c2, 1);
		d2 = c1 ^ ROL(c3, 1);
		d3 = c2 ^ ROL(c4, 1);
		d4 = c3 ^ ROL(c0, 1);

		s[0] ^= d0; s[5] ^= d0; s[10] ^= d0;
		s[15] ^= d0; s[20] ^= d0;
		s[1] ^= d1; s[6] ^= d1; s[11] ^= d1;
		s[16] ^= d1; s[21] ^= d1;
		s[2] ^= d2; s[7] ^= d2; s[12] ^= d2;
		s[17] ^= d2; s[22] ^= d2;
		s[3] ^= d3; s[8] ^= d3; s[13] ^= d3;
		s[18] ^= d3; s[23] ^= d3;
		s[4] ^= d4; s[9] ^= d4; s[14] ^= d4;
		s[19] ^= d4; s[24] ^= d4;

		/* rho and pi: rotate on the way to the new position */
		b[0] = s[0];
		b[10] = ROL(s[1], 1);
		b[20] = ROL(s[2], 62);
		b[5] = ROL(s[3], 28);
		b[15] = ROL(s[4], 27);
		b[16] = ROL(s[5], 36);
		b[1] = ROL(s[6], 44);
		b[11] = ROL(s[7], 6);
		b[21] = ROL(s[8], 55);
		b[6] = ROL(s[9], 20);
		b[7] = ROL(s[10], 3);
		b[17] = ROL(s[11], 10);
		b[2] = ROL(s[12], 43);
		b[12] = ROL(s[13], 25);
		b[22] = ROL(s[14], 39);
		b[23] = ROL(s[15], 41);
		b[8] = ROL(s[16], 45);
		b[18] = ROL(s[17], 15);
		b[3] = ROL(s[18], 21);
		b[13] = ROL(s[19], 8);
		b[14] = ROL(s[20], 18);
		b[24] = ROL(s[21], 2);
		b[9] = ROL(s[22], 61);
		b[19] = ROL(s[23], 56);
		b[4] = ROL(s[24], 14);

		/* chi, a row at a time */
		s[0] = b[0] ^ (~b[1] & b[2]);
		s[1] = b[1] ^ (~b[2] & b[3]);
		s[2] = b[2] ^ (~b[3] & b[4]);
		s[3] = b[3] ^ (~b[4] & b[0]);
		s[4] = b[4] ^ (~b[0] & b[1]);
		s[5] = b[5] ^ (~b[6] & b[7]);
		s[6] = b[6] ^ (~b[7] & b[8]);
		s[7] = b[7] ^ (~b[8] & b[9]);
		s[8] = b[8] ^ (~b[9] & b[5]);
		s[9] = b[9] ^ (~b[5] & b[6]);
		s[10] = b[10] ^ (~b[11] & b[12]);
		s[11] = b[11] ^ (~b[12] & b[13]);
		s[12] = b[12] ^ (~b[13] & b[14]);
		s[13] = b[13] ^ (~b[14] & b[10]);
		s[14] = b[14] ^ (~b[10] & b[11]);
		s[15] = b[15] ^ (~b[16] & b[17]);
		s[16] = b[16] ^ (~b[17] & b[18]);
		s[17] = b[17] ^ (~b[18] & b[19]);
		s[18] = b[18] ^ (~b[19] & b[15]);
		s[19] = b[19] ^ (~b[15] & b[16]);
		s[20] = b[20] ^ (~b[21] & b[22]);
		s[21] = b[21] ^ (~b[22] & b[23]);
		s[22] = b[22] ^ (~b[23] & b[24]);
		s[23] = b[23] ^ (~b[24] & b[20]);
		s[24] = b[24] ^ (~b[20] & b[21]);

		/* iota */
		s[0] ^= KECCAK_RC[r];
	}
}

#undef ROL

static void
keccak_load(uint64_t s[25], const uint8_t state[200])
{
	int i;

	for (i = 0; i < 25; i++)
		s[i] = u64le(state + 8 * i);
}

static void
keccak_store(uint8_t state[200], const uint64_t s[25])
{
	int i;

	for (i = 0; i < 25; i++)
		p64le(state + 8 * i, s[i]);
}

/* The permutation on the byte encoding of the state. */
static void
keccak_permute(uint8_t state[200])
{
	uint64_t s[25];

	keccak_load(s, state);
	keccakf1600(s);
	keccak_store(state, s);
}

/*
 * Absorb a whole message at `rate` bytes a block, apply the domain
 * padding of `pad`, and leave the state ready to squeeze. `state` starts
 * empty here rather than being carried in: every caller hashes one
 * message and then reads from it.
 */
static void
keccak_absorb(uint8_t state[200], const uint8_t *msg, size_t len,
    size_t rate, uint8_t pad)
{
	uint64_t s[25];
	uint8_t tail[200];
	size_t lanes = rate / 8;
	size_t i;

	for (i = 0; i < 25; i++)
		s[i] = 0;

	while (len >= rate) {
		for (i = 0; i < lanes; i++)
			s[i] ^= u64le(msg + 8 * i);
		keccakf1600(s);
		msg += rate;
		len -= rate;
	}

	/* the final block: what is left, the separator, zeroes, and the
	 * high bit of the last byte.
	 */
	for (i = 0; i < len; i++)
		tail[i] = msg[i];
	tail[len] = pad;
	for (i = len + 1; i < rate; i++)
		tail[i] = 0;
	tail[rate - 1] |= 0x80;

	for (i = 0; i < lanes; i++)
		s[i] ^= u64le(tail + 8 * i);
	keccakf1600(s);

	keccak_store(state, s);
}

/*
 * Squeeze `outlen` bytes, permuting between blocks and not after the
 * last one. A caller that wants to go on reading past a block boundary
 * asks for a whole block and then permutes, which is what an incremental
 * SHAKE reader does.
 */
static void
keccak_squeeze(uint8_t state[200], uint8_t *out, size_t outlen, size_t rate)
{
	uint64_t s[25];
	uint8_t block[200];
	size_t lanes = rate / 8;
	size_t i, n;

	keccak_load(s, state);

	for (;;) {
		for (i = 0; i < lanes; i++)
			p64le(block + 8 * i, s[i]);

		n = outlen < rate ? outlen : rate;
		for (i = 0; i < n; i++)
			out[i] = block[i];

		out += n;
		outlen -= n;
		if (outlen == 0)
			break;
		keccakf1600(s);
	}

	keccak_store(state, s);
}

/* ------------------------------------------------------------------ */
/* AES-128 and AES-256, FIPS 197, encryption direction only             */

/*
 * Here because measurement asked for it: at a 1200-byte QUIC datagram
 * the Lua AES-GCM managed about 320 packets a second against ChaCha20's
 * 300,000, and roughly seven tenths of that was the block cipher rather
 * than the GHASH above it. QUIC cannot avoid AES whatever suite it
 * negotiates -- Initial packets are AES-128-GCM under a fixed salt and
 * their header protection is a raw ECB block (RFC 9001 5.2 and 5.4.3).
 *
 * A transliteration of the same FIPS 197 description that
 * ssh/crypto/aes.lua follows, which keeps the two readable against each
 * other and makes the spec suite a differential test of both.
 *
 * Encrypt only: GCM is CTR plus GHASH and CTR never runs the cipher
 * backwards, while header protection is a forward block on a sample. The
 * inverse cipher and its tables are absent because nothing would call
 * them.
 *
 * aes_ctr_xor is the entry point that matters. Exposing a single-block
 * function alone would put a Lua call and a string allocation between
 * every 16 bytes; this expands the key once and runs a whole packet.
 *
 * Two caveats, stated rather than fixed:
 *
 *   - The S-box is a table lookup, so this is not constant-time against
 *     an attacker who can watch the cache. That is the standard tradeoff
 *     for a portable AES with no hardware support, and it is part of why
 *     the negotiated suite is ChaCha20-Poly1305: AES is confined to
 *     Initial packets, whose keys derive from the connection ID and are
 *     therefore public to anyone on the path.
 *   - The table is a constant here rather than computed at load as the
 *     Lua version computes it, because a freestanding module has nowhere
 *     to run an initialiser. The two are checked against each other by
 *     the spec suite, which is what a transcribed table needs.
 */

static const uint8_t SBOX[256] = {
	0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5,
	0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
	0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
	0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
	0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc,
	0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
	0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a,
	0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
	0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
	0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
	0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b,
	0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
	0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85,
	0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
	0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
	0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
	0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17,
	0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
	0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88,
	0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
	0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
	0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
	0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9,
	0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
	0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6,
	0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
	0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
	0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
	0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94,
	0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
	0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68,
	0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
};

/* Round constants, 0x01 doubled in GF(2^8). Ten covers both schedules. */
static const uint8_t RCON[10] = {
	0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
};

#define AES_MAXROUNDS 14

struct aes {
	uint8_t rk[AES_MAXROUNDS + 1][16];
	int rounds;
};

/* Returns 0 for a key length this does not implement. */
static int
aes_expand(struct aes *a, const uint8_t *key, size_t klen)
{
	int nk, nw, i, j;
	uint8_t t[4], tmp;

	if (klen == 16)
		a->rounds = 10;
	else if (klen == 32)
		a->rounds = 14;
	else
		return 0;

	nk = (int)(klen / 4);
	nw = (a->rounds + 1) * 4;

	for (i = 0; i < (int)klen; i++)
		a->rk[i / 16][i % 16] = key[i];

	for (i = nk; i < nw; i++) {
		for (j = 0; j < 4; j++)
			t[j] = a->rk[(i - 1) / 4][((i - 1) % 4) * 4 + j];

		if (i % nk == 0) {
			tmp = t[0];
			t[0] = (uint8_t)(SBOX[t[1]] ^ RCON[i / nk - 1]);
			t[1] = SBOX[t[2]];
			t[2] = SBOX[t[3]];
			t[3] = SBOX[tmp];
		} else if (nk > 6 && i % nk == 4) {
			/* The extra SubWord that only AES-256 has, and the
			 * only structural difference between the two
			 * schedules.
			 */
			for (j = 0; j < 4; j++)
				t[j] = SBOX[t[j]];
		}

		for (j = 0; j < 4; j++)
			a->rk[i / 4][(i % 4) * 4 + j] = (uint8_t)
			    (a->rk[(i - nk) / 4][((i - nk) % 4) * 4 + j] ^ t[j]);
	}

	return 1;
}

/* Multiply by x in GF(2^8), reducing by 0x11b. Branchless, so the high
 * bit does not become a jump.
 */
static uint8_t
xtime(uint8_t x)
{
	return (uint8_t)((uint8_t)(x << 1) ^
	    (uint8_t)(0x1b & (uint8_t)(-(int)(x >> 7))));
}

static void
aes_encrypt_block(const struct aes *a, const uint8_t in[16], uint8_t out[16])
{
	uint8_t s[16], t[16];
	int r, i, c;

	for (i = 0; i < 16; i++)
		s[i] = (uint8_t)(in[i] ^ a->rk[0][i]);

	for (r = 1; r <= a->rounds; r++) {
		for (i = 0; i < 16; i++)
			s[i] = SBOX[s[i]];

		/* ShiftRows: the state is column-major, so the byte at i
		 * takes its value from i + 4*(i%4), modulo the block.
		 */
		for (i = 0; i < 16; i++)
			t[i] = s[(i + 4 * (i % 4)) % 16];

		/* The last round has no MixColumns: with it, the final key
		 * addition would be undoable without the key.
		 */
		if (r != a->rounds) {
			for (c = 0; c < 4; c++) {
				uint8_t *p = t + 4 * c;
				uint8_t a0 = p[0], a1 = p[1];
				uint8_t a2 = p[2], a3 = p[3];
				uint8_t x = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);

				p[0] = (uint8_t)(a0 ^ x ^ xtime((uint8_t)(a0 ^ a1)));
				p[1] = (uint8_t)(a1 ^ x ^ xtime((uint8_t)(a1 ^ a2)));
				p[2] = (uint8_t)(a2 ^ x ^ xtime((uint8_t)(a2 ^ a3)));
				p[3] = (uint8_t)(a3 ^ x ^ xtime((uint8_t)(a3 ^ a0)));
			}
		}

		for (i = 0; i < 16; i++)
			s[i] = (uint8_t)(t[i] ^ a->rk[r][i]);
	}

	for (i = 0; i < 16; i++)
		out[i] = s[i];
}

/*
 * CTR as GCM defines it: only the low 32 bits of the counter block
 * advance, big-endian, wrapping rather than carrying into the nonce.
 * The counter is updated in place, so a caller can continue a stream.
 */
static void
aes_ctr_xor(const struct aes *a, uint8_t ctr[16], uint8_t *restrict out,
    const uint8_t *restrict in, size_t len)
{
	uint8_t ks[16];
	size_t off, i, n;
	uint32_t c;

	for (off = 0; off < len; off += 16) {
		aes_encrypt_block(a, ctr, ks);

		c = ((uint32_t)ctr[12] << 24) | ((uint32_t)ctr[13] << 16) |
		    ((uint32_t)ctr[14] << 8) | (uint32_t)ctr[15];
		c++;
		ctr[12] = (uint8_t)(c >> 24);
		ctr[13] = (uint8_t)(c >> 16);
		ctr[14] = (uint8_t)(c >> 8);
		ctr[15] = (uint8_t)(c);

		n = len - off;
		if (n > 16)
			n = 16;
		for (i = 0; i < n; i++)
			out[off + i] = (uint8_t)(in[off + i] ^ ks[i]);
	}
}

/* ------------------------------------------------------------------ */
/*
 * X25519 and Ed25519.
 *
 * The same TweetNaCl shape the field25519 module carries, in C. The Lua
 * is the reference the RFC vectors run against and the implementation a
 * build without this module gets; a caller that has this one gets this
 * one. Every connection pays for a key exchange and a signature, and
 * the field arithmetic under both is the slowest part of either.
 *
 * The shifts here are arithmetic right shifts. The Lua spells each one
 * as floor division, because Lua's >> is logical and would be silently
 * wrong on a negative limb -- that is the one thing that does not
 * survive a move in either direction. Shifts are also what keeps this
 * inside the freestanding rules at the top of this file: a shift is not
 * a division, so nothing pulls in libgcc's __divdi3 on a target without
 * the instruction.
 *
 * A field element is 10 signed limbs of radix 2^25.5: limb i carries
 * weight 2^ceil(25.5*i), so the widths alternate 26, 25, 26, 25. The
 * limbs are int32_t and the products that accumulate over them are
 * int64_t, which is the one shape every target here multiplies in a
 * single instruction. A 32-bit machine gets 32x32->64 from mul/mulhu on
 * rv32im and mull/mulsh on Xtensa, with no call into libgcc; a 64-bit
 * machine gets one imul. Sixteen 64-bit limbs of radix 2^16 would ask
 * for a full 64x64 multiply, which on a 32-bit target is three
 * multiplies and a shift-add, 256 times per field multiply.
 *
 * The invariant every routine below depends on: a field element handed
 * to fM or fS has |limb| <= 1.65*2^26, and fM and fS return |limb| <=
 * 2^25.5. So a caller may add or subtract two results and multiply
 * again, which is the only pattern the ladder and the point addition
 * use. Limbs are signed between reductions and nothing may assume
 * otherwise before pack25519.
 */

typedef int32_t gf[10];

/* bit width of limb i */
#define FW(i) (((i) & 1) ? 25 : 26)

static const gf gf0;
static const gf gf1 = { 1 };
static const gf _121665 = { 121665, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
static const gf D = { -10913629, 13857413, -15372611, 6949391, 114729,
	-8787816, -6275908, -3247719, -18696448, 21499316 };
static const gf D2 = { -21827239, -5839606, -30745221, 13898782, 229458,
	15978800, -12551817, -6495438, 29715968, 9444199 };
static const gf X = { -14297830, -7645148, 16144683, -16471763, 27570974,
	-2696100, -26142465, 8378389, 20764389, 8758491 };
static const gf Y = { -26843560, -6710886, 13421773, -13421773, 26843546,
	6710886, -13421773, 13421773, -26843546, 26843546 };
static const gf I = { -32595792, -7943725, 9377950, 3500415, 12389472,
	-272473, -25146209, -2005654, 326686, 11406482 };

/* order of the base point, little-endian */
static const int64_t Lorder[32] = {
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
	0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10
};

static void
fset(gf r, const gf a)
{
	int i;

	for (i = 0; i < 10; i++)
		r[i] = a[i];
}

static void
fA(gf o, const gf a, const gf b)
{
	int i;

	for (i = 0; i < 10; i++)
		o[i] = a[i] + b[i];
}

static void
fZ(gf o, const gf a, const gf b)
{
	int i;

	for (i = 0; i < 10; i++)
		o[i] = a[i] - b[i];
}

/*
 * The order in which limbs are carried. One carry reduces a limb to its
 * own width by a rounding shift, so the carry out is the nearest
 * multiple rather than the floor and the remainder stays balanced around
 * zero. The carry out of limb 9 re-enters at limb 0 multiplied by 19,
 * which is the whole of the reduction: 2^255 = 19 mod p.
 *
 * Two sequential passes over all ten limbs would also work and would
 * need twenty-one carries. This needs twelve. It works because each
 * carry roughly halves the excess width of the limb it lands on, so a
 * limb only has to be revisited if something wide reached it: the even
 * and odd halves interleave, limbs 4 and 8 receive a second carry once
 * the limbs below them have settled, and limb 0 receives one after the
 * wrap from limb 9. The rest are done after a single visit.
 *
 * The chain assumes its input is a product of two field elements whose
 * limbs are within the stated 1.65*2^26. It leaves |limb| <= 2^25.5.
 */
static const uint8_t FCARRY[12] = { 0, 4, 1, 5, 2, 6, 3, 7, 4, 8, 9, 0 };

/*
 * 19 * x, as shifts and adds.
 *
 * x is 64 bits here, and a 32-bit target has no 64-bit multiply: the
 * compiler answers `19 * x` with a call to libgcc's __muldi3. Three
 * shifts and two adds are inline everywhere, and 19 is 16 + 2 + 1.
 */
#define MUL19(x) (((x) << 4) + ((x) << 1) + (x))

static void
fcarry(int64_t h[10])
{
	int64_t c;
	int i, k;

	for (i = 0; i < 12; i++) {
		k = FCARRY[i];

		/* The width is 26 for an even limb and 25 for an odd one,
		 * and the two are written out rather than indexed. A shift
		 * by a variable amount is another libgcc call on a 32-bit
		 * target -- __ashrdi3 and __ashldi3 -- and there are two of
		 * them per step here, twelve steps per field multiply.
		 */
		if (k & 1) {
			c = (h[k] + ((int64_t)1 << 24)) >> 25;
			h[k] -= c << 25;
		} else {
			c = (h[k] + ((int64_t)1 << 25)) >> 26;
			h[k] -= c << 26;
		}

		if (k == 9)
			h[0] += MUL19(c);
		else
			h[k + 1] += c;
	}
}

static void
fstore(gf o, int64_t h[10])
{
	int i;

	fcarry(h);
	for (i = 0; i < 10; i++)
		o[i] = (int32_t)h[i];
}

static void
fM(gf o, const gf a, const gf b)
{
	int64_t t[19];
	int i, j;

	int32_t b2[10];

	for (i = 0; i < 19; i++)
		t[i] = 0;

	/* Two odd limbs each carry half a bit more weight than their
	 * index suggests, and the product lands on an even index that
	 * carries neither, so it is doubled. The doubling is hoisted out
	 * of the inner loop: b2 is the odd limbs of b, doubled, and which
	 * of the two arrays the inner loop reads depends only on i.
	 */
	for (j = 0; j < 10; j++)
		b2[j] = (j & 1) ? 2 * b[j] : b[j];

	/* no skip on a zero limb, however tempting: these limbs are
	 * secret and the branch would be a timing signal.
	 */
	for (i = 0; i < 10; i++) {
		const int32_t *row = (i & 1) ? b2 : b;
		int32_t ai = a[i];

		for (j = 0; j < 10; j++)
			t[i + j] += (int64_t)ai * row[j];
	}
	/* limb i + 10 sits 255 bits above limb i */
	for (i = 0; i < 9; i++)
		t[i] += MUL19(t[i + 10]);
	fstore(o, t);
}

/*
 * Squaring. Every off-diagonal product appears twice in fM, so this
 * forms each one once and doubles it: 55 multiplies rather than 100.
 * The doubling for two odd limbs is the same half-bit correction fM
 * makes, and the two doublings compose.
 */
static void
fS(gf o, const gf a)
{
	int64_t t[19], p;
	int i, j;

	for (i = 0; i < 19; i++)
		t[i] = 0;
	for (i = 0; i < 10; i++) {
		for (j = i; j < 10; j++) {
			p = (int64_t)a[i] * a[j];
			if ((i & 1) && (j & 1))
				p *= 2;
			if (i != j)
				p *= 2;
			t[i + j] += p;
		}
	}
	for (i = 0; i < 9; i++)
		t[i] += MUL19(t[i + 10]);
	fstore(o, t);
}

/* constant-time conditional swap; b is 0 or 1 */
static void
sel25519(gf p, gf q, int64_t b)
{
	int32_t t, c = -(int32_t)b;
	int i;

	for (i = 0; i < 10; i++) {
		t = c & (p[i] ^ q[i]);
		p[i] ^= t;
		q[i] ^= t;
	}
}

/*
 * The canonical little-endian encoding. The input is congruent to the
 * value mod p but need not be the least such, so this subtracts the one
 * multiple of p that brings it into range. q is that multiple, found by
 * running the carry chain that the addition of 19 would produce and
 * keeping only whether it overflowed 2^255.
 */
static void
pack25519(uint8_t *o, const gf n)
{
	int64_t h[10], q;
	int i, off;

	for (i = 0; i < 10; i++)
		h[i] = n[i];
	fcarry(h);
	fcarry(h);

	q = (MUL19(h[9]) + (1 << 24)) >> 25;
	for (i = 0; i < 10; i++)
		q = (i & 1) ? ((h[i] + q) >> 25) : ((h[i] + q) >> 26);
	h[0] += MUL19(q);

	/* unsigned carry, so every limb is now its own bit field and the
	 * borrow out of limb 9 is the 2^255 that q already removed
	 */
	for (i = 0; i < 9; i++) {
		if (i & 1) {
			h[i + 1] += h[i] >> 25;
			h[i] -= (h[i] >> 25) << 25;
		} else {
			h[i + 1] += h[i] >> 26;
			h[i] -= (h[i] >> 26) << 26;
		}
	}
	h[9] &= ((int64_t)1 << 25) - 1;

	for (i = 0; i < 32; i++)
		o[i] = 0;
	for (i = 0, off = 0; i < 10; i++) {
		o[off >> 3] |= (uint8_t)(h[i] << (off & 7));
		o[(off >> 3) + 1] |= (uint8_t)(h[i] >> (8 - (off & 7)));
		o[(off >> 3) + 2] |= (uint8_t)(h[i] >> (16 - (off & 7)));
		o[(off >> 3) + 3] |= (uint8_t)(h[i] >> (24 - (off & 7)));
		off += FW(i);
	}
}

/*
 * The inverse. Limb i starts at bit offset sum(FW(0..i-1)), which is
 * never more than bit 230, so a four-byte window at that offset always
 * lies inside the 32 bytes. The top bit of the last byte is not part of
 * the value.
 */
static void
unpack25519(gf o, const uint8_t *n)
{
	uint8_t s[32];
	int64_t h[10], v;
	int i, j, off, w;

	for (i = 0; i < 32; i++)
		s[i] = n[i];
	s[31] &= 0x7f;

	for (i = 0, off = 0; i < 10; i++) {
		w = FW(i);
		v = 0;
		for (j = 0; j < 4; j++)
			v |= (int64_t)s[(off >> 3) + j] << (8 * j);
		v >>= off & 7;
		h[i] = v & (((int64_t)1 << w) - 1);
		off += w;
	}
	fstore(o, h);
}

static int
neq25519(const gf a, const gf b)
{
	uint8_t c[32], d[32];
	int i, diff = 0;

	pack25519(c, a);
	pack25519(d, b);
	for (i = 0; i < 32; i++)
		diff |= c[i] ^ d[i];
	return diff != 0;
}

static uint8_t
par25519(const gf a)
{
	uint8_t d[32];

	pack25519(d, a);
	return d[0] & 1;
}

static void
inv25519(gf o, const gf i)
{
	gf c;
	int a;

	fset(c, i);
	for (a = 253; a >= 0; a--) {
		fS(c, c);
		if (a != 2 && a != 4)
			fM(c, c, i);
	}
	fset(o, c);
}

/* x^((p-5)/8), the square root Ed25519 decompression needs */
static void
pow2523(gf o, const gf i)
{
	gf c;
	int a;

	fset(c, i);
	for (a = 250; a >= 0; a--) {
		fS(c, c);
		if (a != 1)
			fM(c, c, i);
	}
	fset(o, c);
}

/* ---- X25519, RFC 7748 ---- */

/* The Montgomery ladder: 255 iterations of a fixed sequence with two
 * constant-time swaps around it, so the work is independent of the
 * scalar.
 */
static void
x25519(uint8_t *q, const uint8_t *n, const uint8_t *p)
{
	uint8_t z[32];
	gf x, a, b, c, d, e, f;
	int i;
	int64_t r;

	for (i = 0; i < 31; i++)
		z[i] = n[i];
	z[31] = (n[31] & 127) | 64;
	z[0] &= 248;

	unpack25519(x, p);
	for (i = 0; i < 10; i++) {
		b[i] = x[i];
		a[i] = c[i] = d[i] = 0;
	}
	a[0] = d[0] = 1;

	for (i = 254; i >= 0; i--) {
		r = (z[i >> 3] >> (i & 7)) & 1;
		sel25519(a, b, r);
		sel25519(c, d, r);
		fA(e, a, c);
		fZ(a, a, c);
		fA(c, b, d);
		fZ(b, b, d);
		fS(d, e);
		fS(f, a);
		fM(a, c, a);
		fM(c, b, e);
		fA(e, a, c);
		fZ(a, a, c);
		fS(b, a);
		fZ(c, d, f);
		fM(a, c, _121665);
		fA(a, a, d);
		fM(c, c, a);
		fM(a, d, f);
		fM(d, b, x);
		fS(b, e);
		sel25519(a, b, r);
		sel25519(c, d, r);
	}
	inv25519(c, c);
	fM(a, a, c);
	pack25519(q, a);
}

/* ---- Ed25519, RFC 8032 ---- */

/* sha512 of up to three pieces, so signing hashes prefix||message and
 * R||A||message without joining them first. The block function is the
 * one this file already has for the Lua binding.
 */
static void
sha512_3(uint8_t out[64], const uint8_t *a, size_t alen,
    const uint8_t *b, size_t blen, const uint8_t *c, size_t clen)
{
	static const uint8_t iv[64] = {
		0x6a, 0x09, 0xe6, 0x67, 0xf3, 0xbc, 0xc9, 0x08,
		0xbb, 0x67, 0xae, 0x85, 0x84, 0xca, 0xa7, 0x3b,
		0x3c, 0x6e, 0xf3, 0x72, 0xfe, 0x94, 0xf8, 0x2b,
		0xa5, 0x4f, 0xf5, 0x3a, 0x5f, 0x1d, 0x36, 0xf1,
		0x51, 0x0e, 0x52, 0x7f, 0xad, 0xe6, 0x82, 0xd1,
		0x9b, 0x05, 0x68, 0x8c, 0x2b, 0x3e, 0x6c, 0x1f,
		0x1f, 0x83, 0xd9, 0xab, 0xfb, 0x41, 0xbd, 0x6b,
		0x5b, 0xe0, 0xcd, 0x19, 0x13, 0x7e, 0x21, 0x79
	};
	const uint8_t *piece[3];
	size_t plen[3];
	uint8_t buf[256];
	uint64_t total = 0;
	size_t n = 0, i, k;
	int j;

	piece[0] = a;
	plen[0] = alen;
	piece[1] = b;
	plen[1] = blen;
	piece[2] = c;
	plen[2] = clen;

	for (i = 0; i < 64; i++)
		out[i] = iv[i];

	for (j = 0; j < 3; j++) {
		for (k = 0; k < plen[j]; k++) {
			buf[n++] = piece[j][k];
			total++;
			if (n == 128) {
				sha512_blocks(out, buf, 1);
				n = 0;
			}
		}
	}

	/* the tail: 0x80, zeros, then the length in bits as a 128-bit
	 * big-endian count. Two blocks where the padding does not fit in
	 * one, which is the only reason buf is 256 bytes.
	 */
	buf[n++] = 0x80;
	while (n % 128 != 112) {
		buf[n++] = 0;
		if (n == 256)
			break;
	}
	for (i = 0; i < 8; i++)
		buf[n++] = 0;
	total <<= 3;
	for (i = 0; i < 8; i++)
		buf[n++] = (uint8_t)((total >> (56 - 8 * i)) & 0xff);
	sha512_blocks(out, buf, n / 128);
}

/* a point in extended coordinates: x, y, z, t */
static void
ed_add(gf p[4], const gf q[4])
{
	gf a, b, c, d, t, e, f, g, h;

	fZ(a, p[1], p[0]);
	fZ(t, q[1], q[0]);
	fM(a, a, t);
	fA(b, p[0], p[1]);
	fA(t, q[0], q[1]);
	fM(b, b, t);
	fM(c, p[3], q[3]);
	fM(c, c, D2);
	fM(d, p[2], q[2]);
	fA(d, d, d);
	fZ(e, b, a);
	fZ(f, d, c);
	fA(g, d, c);
	fA(h, b, a);

	fM(p[0], e, f);
	fM(p[1], h, g);
	fM(p[2], g, f);
	fM(p[3], e, h);
}

static void
ed_cswap(gf p[4], gf q[4], uint8_t b)
{
	int i;

	for (i = 0; i < 4; i++)
		sel25519(p[i], q[i], b);
}

static void
ed_pack(uint8_t *r, const gf p[4])
{
	gf tx, ty, zi;

	inv25519(zi, p[2]);
	fM(tx, p[0], zi);
	fM(ty, p[1], zi);
	pack25519(r, ty);
	r[31] ^= par25519(tx) << 7;
}

static void
ed_scalarmult(gf p[4], gf q[4], const uint8_t *s)
{
	int i;
	uint8_t b;

	fset(p[0], gf0);
	fset(p[1], gf1);
	fset(p[2], gf1);
	fset(p[3], gf0);
	for (i = 255; i >= 0; i--) {
		b = (s[i >> 3] >> (i & 7)) & 1;
		ed_cswap(p, q, b);
		ed_add(q, (const gf *)p);
		ed_add(p, (const gf *)p);
		ed_cswap(p, q, b);
	}
}

static void
ed_scalarbase(gf p[4], const uint8_t *s)
{
	gf q[4];

	fset(q[0], X);
	fset(q[1], Y);
	fset(q[2], gf1);
	fM(q[3], X, Y);
	ed_scalarmult(p, q, s);
}

/* x mod L, over a 64-limb little-endian value */
static void
modL(uint8_t *r, int64_t x[64])
{
	int64_t carry;
	int i, j;

	for (i = 63; i >= 32; i--) {
		carry = 0;
		for (j = i - 32; j < i - 12; j++) {
			x[j] += carry - 16 * x[i] * Lorder[j - (i - 32)];
			carry = (x[j] + 128) >> 8;
			x[j] -= carry << 8;
		}
		x[j] += carry;
		x[i] = 0;
	}
	carry = 0;
	for (j = 0; j < 32; j++) {
		x[j] += carry - (x[31] >> 4) * Lorder[j];
		carry = x[j] >> 8;
		x[j] &= 255;
	}
	for (j = 0; j < 32; j++)
		x[j] -= carry * Lorder[j];
	for (i = 0; i < 32; i++) {
		x[i + 1] += x[i] >> 8;
		r[i] = (uint8_t)(x[i] & 255);
	}
}

static void
reduce(uint8_t *r)
{
	int64_t x[64];
	int i;

	for (i = 0; i < 64; i++)
		x[i] = r[i];
	for (i = 0; i < 64; i++)
		r[i] = 0;
	modL(r, x);
}

/* decompress a public key to -P, so verification is one addition */
static int
unpackneg(gf r[4], const uint8_t *pk)
{
	gf t, chk, num, den, den2, den4, den6;

	fset(r[2], gf1);
	unpack25519(r[1], pk);
	fS(num, r[1]);
	fM(den, num, D);
	fZ(num, num, r[2]);
	fA(den, r[2], den);

	fS(den2, den);
	fS(den4, den2);
	fM(den6, den4, den2);
	fM(t, den6, num);
	fM(t, t, den);

	pow2523(t, t);
	fM(t, t, num);
	fM(t, t, den);
	fM(t, t, den);
	fM(r[0], t, den);

	fS(chk, r[0]);
	fM(chk, chk, den);
	if (neq25519(chk, num))
		fM(r[0], r[0], I);

	fS(chk, r[0]);
	fM(chk, chk, den);
	if (neq25519(chk, num))
		return 0;

	if (par25519(r[0]) == (pk[31] >> 7))
		fZ(r[0], gf0, r[0]);

	fM(r[3], r[0], r[1]);
	return 1;
}

/* the clamped scalar and the prefix, from a 32-byte seed */
static void
ed_expand(uint8_t d[64], const uint8_t *seed)
{
	sha512_3(d, seed, 32, 0, 0, 0, 0);
	d[0] &= 248;
	d[31] &= 127;
	d[31] |= 64;
}

static void
ed_publickey(uint8_t pk[32], const uint8_t *seed)
{
	uint8_t d[64];
	gf p[4];

	ed_expand(d, seed);
	ed_scalarbase(p, d);
	ed_pack(pk, (const gf *)p);
}

static void
ed_sign(uint8_t sig[64], const uint8_t *seed, const uint8_t *msg,
    size_t mlen)
{
	uint8_t d[64], pk[32], h[64], r[64];
	int64_t x[64];
	gf p[4];
	int i, j;

	ed_expand(d, seed);
	ed_publickey(pk, seed);

	/* the nonce is the hash of the key's second half with the
	 * message, so signing needs no randomness at all.
	 */
	sha512_3(r, d + 32, 32, msg, mlen, 0, 0);
	reduce(r);
	ed_scalarbase(p, r);
	ed_pack(sig, (const gf *)p);

	sha512_3(h, sig, 32, pk, 32, msg, mlen);
	reduce(h);

	for (i = 0; i < 64; i++)
		x[i] = 0;
	for (i = 0; i < 32; i++)
		x[i] = r[i];
	for (i = 0; i < 32; i++)
		for (j = 0; j < 32; j++)
			x[i + j] += (int64_t)h[i] * (int64_t)d[j];
	modL(sig + 32, x);
}

static int
ed_verify(const uint8_t *pk, const uint8_t *msg, size_t mlen,
    const uint8_t *sig)
{
	uint8_t h[64], t[32], s[32];
	gf q[4], p[4], q2[4];
	int i, diff = 0;

	if (!unpackneg(q, pk))
		return 0;

	/* S must be canonical. A non-reduced scalar makes a signature
	 * malleable, which ssh does not care about and a caller might.
	 */
	for (i = 0; i < 32; i++)
		s[i] = sig[32 + i];
	for (i = 31; i >= 0; i--) {
		if (s[i] > Lorder[i])
			return 0;
		if (s[i] < Lorder[i])
			break;
		if (i == 0)
			return 0;
	}

	sha512_3(h, sig, 32, pk, 32, msg, mlen);
	reduce(h);

	ed_scalarmult(p, q, h);
	ed_scalarbase(q2, s);
	ed_add(p, (const gf *)q2);
	ed_pack(t, (const gf *)p);

	for (i = 0; i < 32; i++)
		diff |= sig[i] ^ t[i];
	return diff == 0;
}

/*
 * ---- Montgomery multiplication ------------------------------------
 *
 * What needs it: ECDSA P-256 and RSA signature verification, both of
 * which are a few thousand modular multiplies and almost nothing else.
 * The Lua implementation in ssh/crypto/bignum.lua is the reference and
 * computes exactly the same function.
 *
 * Every value here is a uint32_t and every carry is explicit. The
 * product of two limbs is built out of four 16-bit products rather
 * than with a uint64_t, because a 32-bit target without a widening
 * multiply calls libgcc for that and this code is slowest exactly
 * there. It costs about 2.6 times on x86-64, which is a price a
 * verification that already takes milliseconds can pay.
 *
 * CIOS, Koc's coarsely integrated operand scanning: interleave the
 * multiply with the reduction so the running total never grows past
 * one limb beyond the modulus. The result is a * b * R^-1 mod m, with
 * R = 2^(32k) for k limbs, which is what the caller's `enter` and
 * `leave` account for.
 *
 * Operands are big-endian bytes of the modulus's own length, a
 * multiple of four. Nothing here is constant time: every caller
 * verifies a public value.
 */

#define BIGNUM_MAX_LIMBS 128            /* 4096-bit moduli */

static void
bn_unpack(uint32_t *out, const uint8_t *s, size_t k)
{
	size_t i;

	/* Limb 0 is the least significant, so the bytes are read from
	 * the end.
	 */
	for (i = 0; i < k; i++) {
		const uint8_t *p = s + (k - 1 - i) * 4;

		out[i] = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
		    (uint32_t)p[2] << 8 | (uint32_t)p[3];
	}
}

static void
bn_pack(uint8_t *out, const uint32_t *a, size_t k)
{
	size_t i;

	for (i = 0; i < k; i++) {
		uint8_t *p = out + (k - 1 - i) * 4;
		uint32_t v = a[i];

		p[0] = (uint8_t)(v >> 24);
		p[1] = (uint8_t)(v >> 16);
		p[2] = (uint8_t)(v >> 8);
		p[3] = (uint8_t)v;
	}
}

/* The 64-bit product of two limbs, as a high and a low half.
 *
 * Each half-sized product fits in 32 bits, and the sum below cannot
 * overflow: the largest possible value is (2^32 - 1)^2, which is what
 * the two halves hold exactly.
 */
static void
bn_mul32(uint32_t a, uint32_t b, uint32_t *hi, uint32_t *lo)
{
	uint32_t a0 = a & 0xffff, a1 = a >> 16;
	uint32_t b0 = b & 0xffff, b1 = b >> 16;
	uint32_t p00 = a0 * b0, p01 = a0 * b1;
	uint32_t p10 = a1 * b0, p11 = a1 * b1;
	uint32_t mid = p01 + p10;
	uint32_t h = p11 + (mid >> 16);
	uint32_t l;

	/* The middle sum can carry out of 32 bits, and that carry belongs
	 * to bit 32 of the product, which is bit 16 of the high half.
	 */
	if (mid < p01)
		h += 1u << 16;

	l = p00 + (mid << 16);
	if (l < p00)
		h += 1;

	*hi = h;
	*lo = l;
}

/* acc += v, carrying into *hi. */
static void
bn_addc(uint32_t *acc, uint32_t *hi, uint32_t v)
{
	uint32_t s = *acc + v;

	if (s < v)
		*hi += 1;
	*acc = s;
}

/* out = a - b, returning the borrow. */
static uint32_t
bn_sub(uint32_t *out, const uint32_t *a, const uint32_t *b, size_t k)
{
	uint32_t borrow = 0;
	size_t i;

	for (i = 0; i < k; i++) {
		uint32_t ai = a[i], bi = b[i];
		uint32_t d = ai - bi;
		uint32_t next = d > ai;         /* the subtraction wrapped */

		if (borrow != 0) {
			if (d == 0)
				next = 1;
			d -= 1;
		}
		out[i] = d;
		borrow = next;
	}
	return borrow;
}

/* out = a + b, returning the carry. */
static uint32_t
bn_add(uint32_t *out, const uint32_t *a, const uint32_t *b, size_t k)
{
	uint32_t carry = 0;
	size_t i;

	for (i = 0; i < k; i++) {
		uint32_t s = a[i] + b[i];
		uint32_t next = s < a[i];

		s += carry;
		if (carry != 0 && s == 0)
			next = 1;
		out[i] = s;
		carry = next;
	}
	return carry;
}

/* out = (a + b) mod m, for a and b already under m. */
static int
bn_add_mod(uint8_t *out, const uint8_t *a, const uint8_t *b,
    const uint8_t *m, size_t len)
{
	uint32_t A[BIGNUM_MAX_LIMBS], B[BIGNUM_MAX_LIMBS];
	uint32_t M[BIGNUM_MAX_LIMBS], t[BIGNUM_MAX_LIMBS];
	uint32_t r[BIGNUM_MAX_LIMBS], carry, borrow;
	size_t k = len / 4;

	if (len == 0 || len % 4 != 0 || k > BIGNUM_MAX_LIMBS)
		return 0;

	bn_unpack(A, a, k);
	bn_unpack(B, b, k);
	bn_unpack(M, m, k);

	/* The sum is under 2m, so one conditional subtraction reduces
	 * it. A carry out of the top limb counts as being over, and both
	 * results are computed before either is chosen: the subtraction
	 * has to run whatever the carry says.
	 */
	carry = bn_add(t, A, B, k);
	borrow = bn_sub(r, t, M, k);
	if (carry != 0 || borrow == 0)
		bn_pack(out, r, k);
	else
		bn_pack(out, t, k);
	return 1;
}

/* out = (a - b) mod m, for a and b already under m. */
static int
bn_sub_mod(uint8_t *out, const uint8_t *a, const uint8_t *b,
    const uint8_t *m, size_t len)
{
	uint32_t A[BIGNUM_MAX_LIMBS], B[BIGNUM_MAX_LIMBS];
	uint32_t M[BIGNUM_MAX_LIMBS], t[BIGNUM_MAX_LIMBS];
	uint32_t r[BIGNUM_MAX_LIMBS];
	size_t k = len / 4;

	if (len == 0 || len % 4 != 0 || k > BIGNUM_MAX_LIMBS)
		return 0;

	bn_unpack(A, a, k);
	bn_unpack(B, b, k);
	bn_unpack(M, m, k);

	if (bn_sub(t, A, B, k) != 0) {
		bn_add(r, t, M, k);
		bn_pack(out, r, k);
	} else {
		bn_pack(out, t, k);
	}
	return 1;
}

/* The limb-level Montgomery product, which p256 below shares.
 *
 * t is k + 2 limbs of scratch, supplied by the caller so that neither
 * this nor its callers need a stack frame per call.
 */
static void
bn_mont_mul_limbs(uint32_t *out, const uint32_t *A, const uint32_t *B,
    const uint32_t *M, uint32_t n0, size_t k, uint32_t *t)
{
	size_t i, j;

	for (i = 0; i < k + 2; i++)
		t[i] = 0;

	for (i = 0; i < k; i++) {
		uint32_t bi = B[i], u, c = 0, hi, lo;

		/* t += a * b[i]. The carry out of each column is the high
		 * half plus whatever the two additions carried, and that
		 * sum cannot overflow: the largest total is
		 * (2^32 - 1)^2 + 2 * (2^32 - 1), which is 2^64 - 1.
		 */
		for (j = 0; j < k; j++) {
			bn_mul32(A[j], bi, &hi, &lo);
			bn_addc(&lo, &hi, t[j]);
			bn_addc(&lo, &hi, c);
			t[j] = lo;
			c = hi;
		}
		lo = t[k];
		hi = 0;
		bn_addc(&lo, &hi, c);
		t[k] = lo;
		t[k + 1] += hi;

		/* t += m * u, chosen so the low limb becomes zero, then
		 * shift one limb down. That shift is the division by the
		 * radix that Montgomery reduction replaces a real division
		 * with.
		 */
		u = t[0] * n0;
		bn_mul32(u, M[0], &hi, &lo);
		bn_addc(&lo, &hi, t[0]);
		c = hi;
		for (j = 1; j < k; j++) {
			bn_mul32(u, M[j], &hi, &lo);
			bn_addc(&lo, &hi, t[j]);
			bn_addc(&lo, &hi, c);
			t[j - 1] = lo;
			c = hi;
		}
		lo = t[k];
		hi = 0;
		bn_addc(&lo, &hi, c);
		t[k - 1] = lo;
		t[k] = t[k + 1] + hi;
		t[k + 1] = 0;
	}

	/* One conditional subtraction: the total is under 2m. A carry out
	 * of the top limb counts as being over, which the subtraction's
	 * own borrow cannot see.
	 */
	if (bn_sub(out, t, M, k) != 0 && t[k] == 0) {
		for (j = 0; j < k; j++)
			out[j] = t[j];
	}
}

/* n0 is -m^-1 mod 2^32. Returns 0 for a length this cannot handle. */
static int
bn_mont_mul(uint8_t *out, const uint8_t *a, const uint8_t *b,
    const uint8_t *m, uint32_t n0, size_t len)
{
	uint32_t A[BIGNUM_MAX_LIMBS], B[BIGNUM_MAX_LIMBS];
	uint32_t M[BIGNUM_MAX_LIMBS], t[BIGNUM_MAX_LIMBS + 2];
	uint32_t r[BIGNUM_MAX_LIMBS];
	size_t k = len / 4;

	if (len == 0 || len % 4 != 0 || k > BIGNUM_MAX_LIMBS)
		return 0;

	bn_unpack(A, a, k);
	bn_unpack(B, b, k);
	bn_unpack(M, m, k);
	bn_mont_mul_limbs(r, A, B, M, n0, k, t);
	bn_pack(out, r, k);
	return 1;
}

/*
 * ---- ECDSA P-256 verification -------------------------------------
 *
 * The Lua in ssh/crypto/p256.lua is the reference and computes the same
 * function; this exists because the interpreter around the arithmetic
 * costs as much again as the arithmetic. A verification is about six
 * thousand Montgomery products, and with the multiply alone in C the
 * other half of the time was Lua building a 32-byte string per field
 * operation.
 *
 * Everything is public -- a signature, a public key, a message hash --
 * so nothing here is constant time. There is no signing: that needs a
 * secret scalar and a nonce, and both want the opposite discipline.
 *
 * Points are Jacobian, (X, Y, Z) standing for (X/Z^2, Y/Z^3), so the
 * inversion happens once at the end rather than once per addition.
 * Field elements are in Montgomery form throughout.
 */

#define P256_K 8                        /* 32 bytes, 8 limbs of 32 bits */

static const uint8_t p256_p_be[32] = {
	0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x01,
	0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
	0x00,0x00,0x00,0x00,0xff,0xff,0xff,0xff,
	0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
};

static const uint8_t p256_n_be[32] = {
	0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,
	0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
	0xbc,0xe6,0xfa,0xad,0xa7,0x17,0x9e,0x84,
	0xf3,0xb9,0xca,0xc2,0xfc,0x63,0x25,0x51
};

static const uint8_t p256_b_be[32] = {
	0x5a,0xc6,0x35,0xd8,0xaa,0x3a,0x93,0xe7,
	0xb3,0xeb,0xbd,0x55,0x76,0x98,0x86,0xbc,
	0x65,0x1d,0x06,0xb0,0xcc,0x53,0xb0,0xf6,
	0x3b,0xce,0x3c,0x3e,0x27,0xd2,0x60,0x4b
};

static const uint8_t p256_gx_be[32] = {
	0x6b,0x17,0xd1,0xf2,0xe1,0x2c,0x42,0x47,
	0xf8,0xbc,0xe6,0xe5,0x63,0xa4,0x40,0xf2,
	0x77,0x03,0x7d,0x81,0x2d,0xeb,0x33,0xa0,
	0xf4,0xa1,0x39,0x45,0xd8,0x98,0xc2,0x96
};

static const uint8_t p256_gy_be[32] = {
	0x4f,0xe3,0x42,0xe2,0xfe,0x1a,0x7f,0x9b,
	0x8e,0xe7,0xeb,0x4a,0x7c,0x0f,0x9e,0x16,
	0x2b,0xce,0x33,0x57,0x6b,0x31,0x5e,0xce,
	0xcb,0xb6,0x40,0x68,0x37,0xbf,0x51,0xf5
};

/* One modulus and what Montgomery arithmetic over it needs. */
struct bn_mod {
	uint32_t m[P256_K];
	uint32_t n0;                    /* -m^-1 mod 2^32 */
	uint32_t r2[P256_K];            /* R^2 mod m, so `enter` is a mul */
	uint32_t one[P256_K];           /* 1 in Montgomery form */
};

/* The inverse of an odd limb modulo 2^32, by Newton iteration: each
 * step doubles the number of correct bits.
 */
static uint32_t
bn_inv_limb(uint32_t a)
{
	uint32_t x = 1;
	int i;

	for (i = 0; i < 6; i++)
		x *= 2u - a * x;
	return x;
}

/* out = (a + b) mod m and out = (a - b) mod m, for reduced operands. */
static void
bn_mod_add(uint32_t *out, const uint32_t *a, const uint32_t *b,
    const uint32_t *m, size_t k)
{
	uint32_t t[P256_K], r[P256_K];
	uint32_t carry = bn_add(t, a, b, k);
	uint32_t borrow = bn_sub(r, t, m, k);
	size_t i;

	if (carry != 0 || borrow == 0) {
		for (i = 0; i < k; i++)
			out[i] = r[i];
	} else {
		for (i = 0; i < k; i++)
			out[i] = t[i];
	}
}

static void
bn_mod_sub(uint32_t *out, const uint32_t *a, const uint32_t *b,
    const uint32_t *m, size_t k)
{
	uint32_t t[P256_K], r[P256_K];
	size_t i;

	if (bn_sub(t, a, b, k) != 0) {
		bn_add(r, t, m, k);
		for (i = 0; i < k; i++)
			out[i] = r[i];
	} else {
		for (i = 0; i < k; i++)
			out[i] = t[i];
	}
}

static void
bn_mod_init(struct bn_mod *mod, const uint8_t *bytes)
{
	uint32_t r2[P256_K];
	size_t i;

	bn_unpack(mod->m, bytes, P256_K);
	mod->n0 = (uint32_t)(0u - bn_inv_limb(mod->m[0]));

	/* R^2 mod m by doubling 1 twice as many times as R has bits.
	 * A division would need a divide routine this file does without.
	 */
	for (i = 0; i < P256_K; i++)
		r2[i] = 0;
	r2[0] = 1;
	for (i = 0; i < 2 * 32 * P256_K; i++)
		bn_mod_add(r2, r2, r2, mod->m, P256_K);
	for (i = 0; i < P256_K; i++)
		mod->r2[i] = r2[i];

	for (i = 0; i < P256_K; i++)
		mod->one[i] = 0;
	mod->one[0] = 1;
	{
		uint32_t t[P256_K + 2];

		bn_mont_mul_limbs(mod->one, mod->one, mod->r2, mod->m,
		    mod->n0, P256_K, t);
	}
}

static void
bn_mod_mul(const struct bn_mod *mod, uint32_t *out, const uint32_t *a,
    const uint32_t *b)
{
	uint32_t t[P256_K + 2];

	bn_mont_mul_limbs(out, a, b, mod->m, mod->n0, P256_K, t);
}

static void
bn_mod_enter(const struct bn_mod *mod, uint32_t *out, const uint32_t *a)
{
	bn_mod_mul(mod, out, a, mod->r2);
}

static void
bn_mod_leave(const struct bn_mod *mod, uint32_t *out, const uint32_t *a)
{
	uint32_t one[P256_K];
	size_t i;

	for (i = 0; i < P256_K; i++)
		one[i] = 0;
	one[0] = 1;
	bn_mod_mul(mod, out, a, one);
}

/* out = a^e mod m, with e big-endian bytes, in Montgomery form both
 * ways. Square and multiply, most significant bit first, skipping the
 * leading zeros: the exponent here is a public constant.
 */
static void
bn_mod_exp(const struct bn_mod *mod, uint32_t *out, const uint32_t *a,
    const uint8_t *e, size_t elen)
{
	uint32_t acc[P256_K];
	size_t i, j;
	int bit, started = 0;

	for (i = 0; i < P256_K; i++)
		acc[i] = mod->one[i];

	for (i = 0; i < elen; i++) {
		for (bit = 7; bit >= 0; bit--) {
			int b = (e[i] >> bit) & 1;

			if (started)
				bn_mod_mul(mod, acc, acc, acc);
			if (!b)
				continue;
			if (started) {
				bn_mod_mul(mod, acc, acc, a);
			} else {
				for (j = 0; j < P256_K; j++)
					acc[j] = a[j];
				started = 1;
			}
		}
	}

	for (i = 0; i < P256_K; i++)
		out[i] = acc[i];
}

/* A point in Jacobian coordinates, in Montgomery form. */
struct p256_pt {
	uint32_t x[P256_K];
	uint32_t y[P256_K];
	uint32_t z[P256_K];
};

/* Everything the curve needs, built once. */
static struct {
	int ready;
	struct bn_mod p;                /* the field */
	struct bn_mod n;                /* the order */
	uint32_t b[P256_K];             /* the curve's b, Montgomery form */
	struct p256_pt g;               /* the generator */
} p256;

static int
p256_is_zero(const uint32_t *a)
{
	size_t i;
	uint32_t d = 0;

	for (i = 0; i < P256_K; i++)
		d |= a[i];
	return d == 0;
}

static int
p256_eq(const uint32_t *a, const uint32_t *b)
{
	size_t i;
	uint32_t d = 0;

	for (i = 0; i < P256_K; i++)
		d |= a[i] ^ b[i];
	return d == 0;
}

static void
p256_copy(uint32_t *out, const uint32_t *a)
{
	size_t i;

	for (i = 0; i < P256_K; i++)
		out[i] = a[i];
}

static void
p256_init(void)
{
	uint32_t t[P256_K];

	if (p256.ready)
		return;

	bn_mod_init(&p256.p, p256_p_be);
	bn_mod_init(&p256.n, p256_n_be);

	bn_unpack(t, p256_b_be, P256_K);
	bn_mod_enter(&p256.p, p256.b, t);

	bn_unpack(t, p256_gx_be, P256_K);
	bn_mod_enter(&p256.p, p256.g.x, t);
	bn_unpack(t, p256_gy_be, P256_K);
	bn_mod_enter(&p256.p, p256.g.y, t);
	p256_copy(p256.g.z, p256.p.one);

	p256.ready = 1;
}

#define FMUL(o, a, b) bn_mod_mul(&p256.p, (o), (a), (b))
#define FADD(o, a, b) bn_mod_add((o), (a), (b), p256.p.m, P256_K)
#define FSUB(o, a, b) bn_mod_sub((o), (a), (b), p256.p.m, P256_K)

/* Doubling, with a = -3 (the "dbl-2001-b" formulas). */
static void
p256_double(struct p256_pt *o, const struct p256_pt *a)
{
	uint32_t delta[P256_K], gamma[P256_K], beta[P256_K], alpha[P256_K];
	uint32_t t1[P256_K], t2[P256_K];

	if (p256_is_zero(a->z)) {
		*o = *a;
		return;
	}

	FMUL(delta, a->z, a->z);
	FMUL(gamma, a->y, a->y);
	FMUL(beta, a->x, gamma);

	FSUB(t1, a->x, delta);           /* x - delta */
	FADD(t2, t1, t1);
	FADD(t1, t2, t1);                /* 3 * (x - delta) */
	FADD(t2, a->x, delta);
	FMUL(alpha, t1, t2);

	FADD(t1, beta, beta);
	FADD(t1, t1, t1);                /* 4 * beta */
	FADD(t2, t1, t1);                /* 8 * beta */
	FMUL(o->x, alpha, alpha);
	FSUB(o->x, o->x, t2);

	FADD(t2, a->y, a->z);
	FMUL(t2, t2, t2);
	FSUB(t2, t2, gamma);
	FSUB(o->z, t2, delta);

	FSUB(t1, t1, o->x);              /* 4 * beta - x3 */
	FMUL(t1, alpha, t1);
	FMUL(t2, gamma, gamma);
	FADD(t2, t2, t2);
	FADD(t2, t2, t2);
	FADD(t2, t2, t2);                /* 8 * gamma^2 */
	FSUB(o->y, t1, t2);
}

/* Addition of two Jacobian points ("add-2007-bl"). */
static void
p256_add(struct p256_pt *o, const struct p256_pt *a, const struct p256_pt *b)
{
	uint32_t z1z1[P256_K], z2z2[P256_K], u1[P256_K], u2[P256_K];
	uint32_t s1[P256_K], s2[P256_K], h[P256_K], i[P256_K], j[P256_K];
	uint32_t r[P256_K], v[P256_K], t1[P256_K];

	if (p256_is_zero(a->z)) {
		*o = *b;
		return;
	}
	if (p256_is_zero(b->z)) {
		*o = *a;
		return;
	}

	FMUL(z1z1, a->z, a->z);
	FMUL(z2z2, b->z, b->z);
	FMUL(u1, a->x, z2z2);
	FMUL(u2, b->x, z1z1);
	FMUL(s1, a->y, b->z);
	FMUL(s1, s1, z2z2);
	FMUL(s2, b->y, a->z);
	FMUL(s2, s2, z1z1);

	if (p256_eq(u1, u2)) {
		/* The same point, or two that cancel. */
		if (!p256_eq(s1, s2)) {
			size_t k;

			for (k = 0; k < P256_K; k++) {
				o->x[k] = 0;
				o->z[k] = 0;
			}
			p256_copy(o->y, p256.p.one);
			return;
		}
		p256_double(o, a);
		return;
	}

	FSUB(h, u2, u1);
	FADD(i, h, h);
	FMUL(i, i, i);
	FMUL(j, h, i);
	FSUB(r, s2, s1);
	FADD(r, r, r);
	FMUL(v, u1, i);

	FMUL(t1, r, r);
	FSUB(t1, t1, j);
	FSUB(o->x, t1, v);
	FSUB(o->x, o->x, v);

	FSUB(t1, v, o->x);
	FMUL(t1, r, t1);
	FMUL(v, s1, j);
	FADD(v, v, v);
	FSUB(o->y, t1, v);

	FADD(t1, a->z, b->z);
	FMUL(t1, t1, t1);
	FSUB(t1, t1, z1z1);
	FSUB(t1, t1, z2z2);
	FMUL(o->z, t1, h);
}

/* y^2 = x^3 - 3x + b, in Montgomery form. */
static int
p256_on_curve(const uint32_t *x, const uint32_t *y)
{
	uint32_t lhs[P256_K], rhs[P256_K], t[P256_K];

	FMUL(rhs, x, x);
	FMUL(rhs, rhs, x);
	FADD(t, x, x);
	FADD(t, t, x);
	FSUB(rhs, rhs, t);
	FADD(rhs, rhs, p256.b);
	FMUL(lhs, y, y);
	return p256_eq(lhs, rhs);
}

/* An uncompressed SEC 1 point, 0x04 then X then Y. */
static int
p256_point(struct p256_pt *o, const uint8_t *s, size_t len)
{
	uint32_t x[P256_K], y[P256_K];

	if (len != 65 || s[0] != 0x04)
		return 0;

	bn_unpack(x, s + 1, P256_K);
	bn_unpack(y, s + 33, P256_K);

	/* Both coordinates must be reduced already. */
	{
		uint32_t scratch[P256_K];

		if (bn_sub(scratch, x, p256.p.m, P256_K) == 0)
			return 0;
		if (bn_sub(scratch, y, p256.p.m, P256_K) == 0)
			return 0;
	}

	bn_mod_enter(&p256.p, o->x, x);
	bn_mod_enter(&p256.p, o->y, y);
	p256_copy(o->z, p256.p.one);

	if (p256_is_zero(o->x) && p256_is_zero(o->y))
		return 0;
	return p256_on_curve(o->x, o->y);
}

/*
 * u1 * G + u2 * Q, by Shamir's trick: one pass over the bits of both
 * scalars with the four combinations precomputed.
 */
static void
p256_double_scalar_mul(struct p256_pt *o, const uint8_t *u1,
    const uint8_t *u2, const struct p256_pt *q)
{
	struct p256_pt tab[4], acc;
	size_t i, k;
	int bit, started = 0;

	for (k = 0; k < P256_K; k++) {
		tab[0].x[k] = 0;
		tab[0].y[k] = 0;
		tab[0].z[k] = 0;
	}
	p256_copy(tab[0].y, p256.p.one);
	tab[1] = p256.g;
	tab[2] = *q;
	p256_add(&tab[3], &p256.g, q);
	acc = tab[0];

	for (i = 0; i < 32; i++) {
		for (bit = 7; bit >= 0; bit--) {
			int idx = ((u1[i] >> bit) & 1) |
			    (((u2[i] >> bit) & 1) << 1);

			if (started)
				p256_double(&acc, &acc);
			if (idx == 0)
				continue;
			if (started) {
				p256_add(&acc, &acc, &tab[idx]);
			} else {
				acc = tab[idx];
				started = 1;
			}
		}
	}
	*o = acc;
}

/*
 * verify(pubkey, hash, r, s) -> 1 when the signature is this key's over
 * this hash. SEC 1 4.1.4, with the hash the full width of the order.
 */
static int
p256_verify(const uint8_t *pub, size_t publen, const uint8_t *hash,
    size_t hashlen, const uint8_t *rb, const uint8_t *sb)
{
	struct p256_pt q, point;
	uint32_t r[P256_K], s[P256_K], e[P256_K];
	uint32_t w[P256_K], u1[P256_K], u2[P256_K], zinv[P256_K], x[P256_K];
	uint8_t u1b[32], u2b[32], xb[32], exp[32];
	size_t i;

	p256_init();

	if (hashlen != 32)
		return 0;
	if (!p256_point(&q, pub, publen))
		return 0;

	bn_unpack(r, rb, P256_K);
	bn_unpack(s, sb, P256_K);
	if (p256_is_zero(r) || p256_is_zero(s))
		return 0;
	{
		uint32_t scratch[P256_K];

		if (bn_sub(scratch, r, p256.n.m, P256_K) == 0)
			return 0;
		if (bn_sub(scratch, s, p256.n.m, P256_K) == 0)
			return 0;
	}

	/* The hash is reduced modulo the order; it is the same width, so
	 * one conditional subtraction is enough. No borrow out means the
	 * subtraction was the one wanted.
	 */
	bn_unpack(e, hash, P256_K);
	{
		uint32_t scratch[P256_K];

		if (bn_sub(scratch, e, p256.n.m, P256_K) == 0)
			p256_copy(e, scratch);
	}

	/* w = s^-1 mod n, by Fermat: the order is prime. */
	for (i = 0; i < 32; i++)
		exp[i] = p256_n_be[i];
	exp[31] -= 2;                   /* n ends in 0x51, so no borrow */
	bn_mod_enter(&p256.n, w, s);
	bn_mod_exp(&p256.n, w, w, exp, 32);

	bn_mod_enter(&p256.n, u1, e);
	bn_mod_mul(&p256.n, u1, u1, w);
	bn_mod_leave(&p256.n, u1, u1);

	bn_mod_enter(&p256.n, u2, r);
	bn_mod_mul(&p256.n, u2, u2, w);
	bn_mod_leave(&p256.n, u2, u2);

	bn_pack(u1b, u1, P256_K);
	bn_pack(u2b, u2, P256_K);

	p256_double_scalar_mul(&point, u1b, u2b, &q);
	if (p256_is_zero(point.z))
		return 0;

	/* Back to affine: one inversion, at the end. */
	for (i = 0; i < 32; i++)
		exp[i] = p256_p_be[i];
	exp[31] -= 2;                   /* p ends in 0xff */
	bn_mod_exp(&p256.p, zinv, point.z, exp, 32);
	FMUL(x, zinv, zinv);
	FMUL(x, point.x, x);
	bn_mod_leave(&p256.p, x, x);
	bn_pack(xb, x, P256_K);

	/* The comparison is modulo the order, and p is larger than n, so
	 * one subtraction reduces it.
	 */
	bn_unpack(x, xb, P256_K);
	{
		uint32_t scratch[P256_K];

		if (bn_sub(scratch, x, p256.n.m, P256_K) == 0)
			p256_copy(x, scratch);
	}
	return p256_eq(x, r);
}
