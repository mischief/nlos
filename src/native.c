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
 * The shifts here are arithmetic right shifts, as TweetNaCl's are. The
 * Lua spells each one as floor division, because Lua's >> is logical
 * and would be silently wrong on a negative limb -- that is the one
 * thing that does not survive a move in either direction. Shifts are
 * also what keeps this inside the freestanding rules at the top of this
 * file: a shift is not a division, so nothing pulls in libgcc's
 * __divdi3 on a target without the instruction.
 *
 * A field element is 16 signed limbs of radix 2^16. Limbs are allowed
 * to go negative between reductions and nothing may assume otherwise
 * before pack25519.
 */

typedef int64_t gf[16];

static const gf gf0;
static const gf gf1 = { 1 };
static const gf _121665 = { 0xDB41, 1 };
static const gf D = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141,
	0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f,
	0x6cee, 0x5203 };
static const gf D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283,
	0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df,
	0xd9dc, 0x2406 };
static const gf X = { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525,
	0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e,
	0x36d3, 0x2169 };
static const gf Y = { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
	0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
	0x6666, 0x6666 };
static const gf I = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f,
	0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1,
	0x2480, 0x2b83 };

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

	for (i = 0; i < 16; i++)
		r[i] = a[i];
}

static void
fA(gf o, const gf a, const gf b)
{
	int i;

	for (i = 0; i < 16; i++)
		o[i] = a[i] + b[i];
}

static void
fZ(gf o, const gf a, const gf b)
{
	int i;

	for (i = 0; i < 16; i++)
		o[i] = a[i] - b[i];
}

static void
car25519(gf o)
{
	int i;
	int64_t c;

	for (i = 0; i < 16; i++) {
		o[i] += (int64_t)1 << 16;
		c = o[i] >> 16;
		o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
		o[i] -= c << 16;
	}
}

static void
fM(gf o, const gf a, const gf b)
{
	int64_t t[31];
	int i, j;

	for (i = 0; i < 31; i++)
		t[i] = 0;
	/* no skip on a zero limb, however tempting: these limbs are
	 * secret and the branch would be a timing signal.
	 */
	for (i = 0; i < 16; i++)
		for (j = 0; j < 16; j++)
			t[i + j] += a[i] * b[j];
	for (i = 0; i < 15; i++)
		t[i] += 38 * t[i + 16];
	for (i = 0; i < 16; i++)
		o[i] = t[i];
	car25519(o);
	car25519(o);
}

static void
fS(gf o, const gf a)
{
	fM(o, a, a);
}

/* constant-time conditional swap; b is 0 or 1 */
static void
sel25519(gf p, gf q, int64_t b)
{
	int64_t t, c = ~(b - 1);
	int i;

	for (i = 0; i < 16; i++) {
		t = c & (p[i] ^ q[i]);
		p[i] ^= t;
		q[i] ^= t;
	}
}

static void
pack25519(uint8_t *o, const gf n)
{
	gf m, t;
	int i, j;
	int64_t b;

	fset(t, n);
	car25519(t);
	car25519(t);
	car25519(t);
	for (j = 0; j < 2; j++) {
		m[0] = t[0] - 0xffed;
		for (i = 1; i < 15; i++) {
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
			m[i - 1] &= 0xffff;
		}
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
		b = (m[15] >> 16) & 1;
		m[14] &= 0xffff;
		sel25519(t, m, 1 - b);
	}
	for (i = 0; i < 16; i++) {
		o[2 * i] = (uint8_t)(t[i] & 0xff);
		o[2 * i + 1] = (uint8_t)((t[i] >> 8) & 0xff);
	}
}

static void
unpack25519(gf o, const uint8_t *n)
{
	int i;

	for (i = 0; i < 16; i++)
		o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
	o[15] &= 0x7fff;
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
	for (i = 0; i < 16; i++) {
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

/* sha256_blocks(state, data) -> state.  `data` must be a whole number of
 * 64-byte blocks; the caller does the buffering, because the caller is
 * ssh.crypto.hashstate and it already does.
 */
static int
l_sha256_blocks(lua_State *L)
{
	uint8_t st[32];
	const uint8_t *state = checkbytes(L, 1, sizeof(st), "sha256 state");
	size_t len, i;
	const char *data = luaL_checklstring(L, 2, &len);

	if (len % 64 != 0)
		return luaL_error(L, "sha256 data must be whole blocks");

	for (i = 0; i < sizeof(st); i++)
		st[i] = state[i];
	sha256_blocks(st, (const uint8_t *)data, len / 64);

	lua_pushlstring(L, (const char *)st, sizeof(st));
	return 1;
}

/* sha512_blocks(state, data) -> state, in 128-byte blocks. */
static int
l_sha512_blocks(lua_State *L)
{
	uint8_t st[64];
	const uint8_t *state = checkbytes(L, 1, sizeof(st), "sha512 state");
	size_t len, i;
	const char *data = luaL_checklstring(L, 2, &len);

	if (len % 128 != 0)
		return luaL_error(L, "sha512 data must be whole blocks");

	for (i = 0; i < sizeof(st); i++)
		st[i] = state[i];
	sha512_blocks(st, (const uint8_t *)data, len / 128);

	lua_pushlstring(L, (const char *)st, sizeof(st));
	return 1;
}

/* A key of 16 or 32 bytes, expanded. */
static void
checkaeskey(lua_State *L, int idx, struct aes *a)
{
	size_t len;
	const char *key = luaL_checklstring(L, idx, &len);

	if (!aes_expand(a, (const uint8_t *)key, len))
		luaL_error(L, "aes key must be 16 or 32 bytes, got %d",
		    (int)len);
}

/* aes_ecb_block(key, block) -> 16 bytes. Header protection, and nothing
 * else: a general ECB mode over a longer message is not something this
 * should grow.
 */
static int
l_aes_ecb_block(lua_State *L)
{
	struct aes a;
	const uint8_t *in;
	uint8_t out[16];

	checkaeskey(L, 1, &a);
	in = checkbytes(L, 2, 16, "aes block");
	aes_encrypt_block(&a, in, out);
	lua_pushlstring(L, (const char *)out, sizeof(out));
	return 1;
}

/* aes_ctr_xor(key, counter, data) -> data. The counter block is passed by
 * value and the advanced one is not returned: GCM derives each packet's
 * starting counter from its nonce, so no caller needs to continue a
 * stream across calls.
 */
static int
l_aes_ctr_xor(lua_State *L)
{
	struct aes a;
	const uint8_t *ctr0;
	uint8_t ctr[16];
	size_t len, i;
	const char *in;
	luaL_Buffer b;
	char *out;

	checkaeskey(L, 1, &a);
	ctr0 = checkbytes(L, 2, 16, "aes counter");
	in = luaL_checklstring(L, 3, &len);

	if (len == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	for (i = 0; i < 16; i++)
		ctr[i] = ctr0[i];

	out = luaL_buffinitsize(L, &b, len);
	aes_ctr_xor(&a, ctr, (uint8_t *)out, (const uint8_t *)in, len);
	luaL_pushresultsize(&b, len);
	return 1;
}

/* Declared before the definition because lua-os builds with
 * -Wmissing-prototypes and this is the one symbol here with external
 * linkage.
 */
int luaopen_ssh_crypto_native(lua_State *L);

/* x25519(scalar, point) -> 32 bytes */
static int
l_x25519(lua_State *L)
{
	const uint8_t *n = checkbytes(L, 1, 32, "x25519 scalar");
	const uint8_t *p = checkbytes(L, 2, 32, "x25519 point");
	uint8_t q[32];

	x25519(q, n, p);
	lua_pushlstring(L, (const char *)q, sizeof(q));
	return 1;
}

/* ed25519_publickey(seed) -> 32 bytes */
static int
l_ed25519_publickey(lua_State *L)
{
	const uint8_t *seed = checkbytes(L, 1, 32, "ed25519 seed");
	uint8_t pk[32];

	ed_publickey(pk, seed);
	lua_pushlstring(L, (const char *)pk, sizeof(pk));
	return 1;
}

/* ed25519_sign(seed, msg) -> 64 bytes, detached */
static int
l_ed25519_sign(lua_State *L)
{
	const uint8_t *seed = checkbytes(L, 1, 32, "ed25519 seed");
	size_t mlen;
	const char *msg = luaL_checklstring(L, 2, &mlen);
	uint8_t sig[64];

	ed_sign(sig, seed, (const uint8_t *)msg, mlen);
	lua_pushlstring(L, (const char *)sig, sizeof(sig));
	return 1;
}

/* ed25519_verify(pk, msg, sig) -> boolean.
 *
 * Never raises on a malformed key or signature: this runs on data an
 * unauthenticated peer chose, so a wrong length is false and not an
 * error the caller has to remember to pcall.
 */
static int
l_ed25519_verify(lua_State *L)
{
	size_t pklen, mlen, siglen;
	const char *pk = luaL_checklstring(L, 1, &pklen);
	const char *msg = luaL_checklstring(L, 2, &mlen);
	const char *sig = luaL_checklstring(L, 3, &siglen);

	if (pklen != 32 || siglen != 64) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, ed_verify((const uint8_t *)pk,
	    (const uint8_t *)msg, mlen, (const uint8_t *)sig));
	return 1;
}

static const luaL_Reg funcs[] = {
	{ "x25519", l_x25519 },
	{ "ed25519_publickey", l_ed25519_publickey },
	{ "ed25519_sign", l_ed25519_sign },
	{ "ed25519_verify", l_ed25519_verify },
	{ "chacha20_block", l_chacha20_block },
	{ "chacha20_xor", l_chacha20_xor },
	{ "poly1305_auth", l_poly1305_auth },
	{ "sha256_blocks", l_sha256_blocks },
	{ "sha512_blocks", l_sha512_blocks },
	{ "aes_ecb_block", l_aes_ecb_block },
	{ "aes_ctr_xor", l_aes_ctr_xor },
	{ NULL, NULL }
};

int
luaopen_ssh_crypto_native(lua_State *L)
{
	luaL_newlib(L, funcs);
	return 1;
}
