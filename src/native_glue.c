/*
 * The Lua binding for src/native.c.
 *
 * Separate from the crypto so that the algorithms can be copied into a
 * freestanding tree unchanged. native.c is included rather than linked
 * because everything in it is static, and static is right: nothing
 * outside it should reach these functions. Including it also keeps the
 * calls direct, with no declarations to hold in step.
 *
 * This file is the only part that needs a hosted build.
 *
 * Maintained here rather than copied: src/native.c comes from the ssh
 * tree unchanged, and this side is where a payload learns to be a
 * los.buf as well as a string.
 */

#include "native.c"

#include "buf.h"
#include "lua.h"
#include "lauxlib.h"

static const uint8_t *
checkbytes(lua_State *L, int idx, size_t want, const char *what)
{
	size_t len;
	const char *s = luabuf_check(L, idx, &len);

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
	const char *in = luabuf_check(L, 4, &len);
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
	const char *m = luabuf_check(L, 2, &len);
	struct poly1305 st;
	uint8_t tag[16];

	poly1305_init(&st, key);
	poly1305_update(&st, (const uint8_t *)m, len);
	poly1305_finish(&st, tag);

	lua_pushlstring(L, (const char *)tag, sizeof(tag));
	return 1;
}

/* A sponge rate, in bytes: a whole number of lanes, and short enough to
 * leave the capacity the standard asks for. The caller names it, because
 * the rate is what tells SHA3-256 from SHAKE256.
 */
static size_t
checkrate(lua_State *L, int idx)
{
	lua_Integer rate = luaL_checkinteger(L, idx);

	if (rate < 8 || rate > 200 || rate % 8 != 0)
		luaL_error(L, "keccak rate must be 8..200 and a multiple of 8");
	return (size_t)rate;
}

/* keccak_absorb(msg, rate, pad) -> 200-byte state */
static int
l_keccak_absorb(lua_State *L)
{
	size_t len;
	const char *msg = luabuf_check(L, 1, &len);
	size_t rate = checkrate(L, 2);
	lua_Integer pad = luaL_checkinteger(L, 3);
	uint8_t state[200];

	if (pad < 0 || pad > 0xff)
		return luaL_error(L, "keccak pad must be a byte");

	keccak_absorb(state, (const uint8_t *)msg, len, rate, (uint8_t)pad);
	lua_pushlstring(L, (const char *)state, sizeof(state));
	return 1;
}

/* keccak_squeeze(state, rate, n) -> n bytes, state */
static int
l_keccak_squeeze(lua_State *L)
{
	const uint8_t *in = checkbytes(L, 1, 200, "keccak state");
	size_t rate = checkrate(L, 2);
	lua_Integer n = luaL_checkinteger(L, 3);
	uint8_t state[200];
	luaL_Buffer b;
	char *out;
	size_t i;

	if (n < 0)
		return luaL_error(L, "keccak output length must not be negative");

	for (i = 0; i < sizeof(state); i++)
		state[i] = in[i];

	out = luaL_buffinitsize(L, &b, (size_t)n);
	keccak_squeeze(state, (uint8_t *)out, (size_t)n, rate);
	luaL_pushresultsize(&b, (size_t)n);

	lua_pushlstring(L, (const char *)state, sizeof(state));
	return 2;
}

/* keccak_permute(state) -> state */
static int
l_keccak_permute(lua_State *L)
{
	const uint8_t *in = checkbytes(L, 1, 200, "keccak state");
	uint8_t state[200];
	size_t i;

	for (i = 0; i < sizeof(state); i++)
		state[i] = in[i];

	keccak_permute(state);
	lua_pushlstring(L, (const char *)state, sizeof(state));
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
	const char *data = luabuf_check(L, 2, &len);

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
	const char *data = luabuf_check(L, 2, &len);

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
	const char *key = luabuf_check(L, idx, &len);

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
	in = luabuf_check(L, 3, &len);

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
	const char *msg = luabuf_check(L, 2, &mlen);
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
	const char *pk = luabuf_check(L, 1, &pklen);
	const char *msg = luabuf_check(L, 2, &mlen);
	const char *sig = luabuf_check(L, 3, &siglen);

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
	{ "keccak_absorb", l_keccak_absorb },
	{ "keccak_squeeze", l_keccak_squeeze },
	{ "keccak_permute", l_keccak_permute },
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
