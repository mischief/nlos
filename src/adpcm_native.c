/* IMA ADPCM, decoded a block at a time. lib/adpcm.lua is the reference
 * and is checked against this one; it earns C by being the hot loop.
 * 48kHz stereo is 96000 nibbles a second while the bus wants a packet
 * every millisecond, and the Lua one on an S3 plays a twenty second
 * track over 167 seconds.
 */

#include <stdint.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

static const int8_t indextab[16] = {
	-1, -1, -1, -1, 2, 4, 6, 8,
	-1, -1, -1, -1, 2, 4, 6, 8
};

static const int16_t steptab[89] = {
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
	19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
	130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
	5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

/* at most what a wav block align can name */
#define MAXCH 2

static inline int
nibble(int *pred, int *idx, unsigned nib)
{
	int s = steptab[*idx];
	int d = s >> 3;
	int p = *pred;
	int i;

	if (nib & 4)
		d += s;
	if (nib & 2)
		d += s >> 1;
	if (nib & 1)
		d += s >> 2;
	if (nib & 8)
		p -= d;
	else
		p += d;

	if (p > 32767)
		p = 32767;
	else if (p < -32768)
		p = -32768;

	i = *idx + indextab[nib];
	if (i < 0)
		i = 0;
	else if (i > 88)
		i = 88;

	*pred = p;
	*idx = i;
	return p;
}

/* adpcm.block(s, at, channels, len) -> pcm, or nil and why.
 *
 * The same signature as the Lua one, `at` one-based, so the two are
 * interchangeable and the test can run either.
 */
static int
l_block(lua_State *L)
{
	size_t slen;
	const char *s = luaL_checklstring(L, 1, &slen);
	lua_Integer at = luaL_checkinteger(L, 2);
	lua_Integer ch = luaL_checkinteger(L, 3);
	lua_Integer len = luaL_optinteger(L, 4, 0);
	const unsigned char *p;
	int pred[MAXCH], idx[MAXCH];
	luaL_Buffer b;
	lua_Integer c, left;

	if (ch < 1 || ch > MAXCH) {
		lua_pushnil(L);
		lua_pushstring(L, "unsupported channel count");
		return 2;
	}
	if (at < 1 || (size_t)at > slen) {
		lua_pushnil(L);
		lua_pushstring(L, "short block");
		return 2;
	}
	if (len <= 0)
		len = (lua_Integer)slen - at + 1;
	if (len < ch * 4 || (size_t)(at + len - 1) > slen) {
		lua_pushnil(L);
		lua_pushstring(L, "short block");
		return 2;
	}

	p = (const unsigned char *)s + at - 1;

	for (c = 0; c < ch; c++) {
		int v = p[c * 4] | (p[c * 4 + 1] << 8);

		if (v >= 32768)
			v -= 65536;
		pred[c] = v;
		idx[c] = p[c * 4 + 2];
		if (idx[c] > 88) {
			lua_pushnil(L);
			lua_pushstring(L, "bad step index");
			return 2;
		}
	}

	luaL_buffinit(L, &b);

	/* the predictor is the first sample, not a value before it */
	for (c = 0; c < ch; c++) {
		luaL_addchar(&b, (char)(pred[c] & 0xff));
		luaL_addchar(&b, (char)((pred[c] >> 8) & 0xff));
	}

	p += ch * 4;
	left = len - ch * 4;

	/* eight samples of each channel in turn, which is how the format
	 * interleaves: runs of four bytes, not sample by sample.
	 */
	while (left >= ch * 4) {
		int16_t run[MAXCH][8];
		int k;

		for (c = 0; c < ch; c++) {
			int pr = pred[c], ix = idx[c];

			for (k = 0; k < 4; k++) {
				unsigned byte = p[k];

				run[c][k * 2] =
				    (int16_t)nibble(&pr, &ix, byte & 0x0f);
				run[c][k * 2 + 1] =
				    (int16_t)nibble(&pr, &ix, byte >> 4);
			}
			pred[c] = pr;
			idx[c] = ix;
			p += 4;
			left -= 4;
		}

		for (k = 0; k < 8; k++) {
			for (c = 0; c < ch; c++) {
				int v = run[c][k];

				luaL_addchar(&b, (char)(v & 0xff));
				luaL_addchar(&b, (char)((v >> 8) & 0xff));
			}
		}
	}

	luaL_pushresult(&b);
	return 1;
}

/* samples(blockalign, channels) -> frames one block holds */
static int
l_samples(lua_State *L)
{
	lua_Integer align = luaL_checkinteger(L, 1);
	lua_Integer ch = luaL_checkinteger(L, 2);

	if (ch < 1) {
		return luaL_error(L, "channels");
	}
	lua_pushinteger(L, 1 + ((align - ch * 4) * 2) / ch);
	return 1;
}

static const luaL_Reg lib[] = {
	{ "block", l_block },
	{ "samples", l_samples },
	{ NULL, NULL }
};

int luaopen_adpcm_native(lua_State *L);

int
luaopen_adpcm_native(lua_State *L)
{
	luaL_newlib(L, lib);
	return 1;
}
