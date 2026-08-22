/* Volume, on the samples themselves: neither device here has one of
 * its own, so the level is applied to the bytes on the way past. That
 * is 96000 multiplies a second at 48kHz stereo, far too many for lua.
 */

#include <stdint.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

/* gain(pcm, q) -> pcm, where q is 0..256 and 256 is unchanged. Signed
 * 16-bit little-endian frames, which is the only width either device
 * is offered.
 */
static int
l_gain(lua_State *L)
{
	size_t n;
	const char *p = luaL_checklstring(L, 1, &n);
	lua_Integer q = luaL_checkinteger(L, 2);
	size_t i, pairs = n / 2;
	luaL_Buffer b;
	char *out;

	if (q < 0)
		q = 0;
	if (q == 256) {
		lua_settop(L, 1);
		return 1;
	}

	out = luaL_buffinitsize(L, &b, n);
	for (i = 0; i < pairs; i++) {
		const unsigned char *s = (const unsigned char *)p + i * 2;
		int32_t v = (int16_t)(s[0] | (s[1] << 8));

		v = (v * (int32_t)q) >> 8;
		/* a q above 256 is amplification, and what it overflows
		 * into is the opposite sign -- a loud click rather than a
		 * loud sample.
		 */
		if (v > 32767)
			v = 32767;
		else if (v < -32768)
			v = -32768;
		out[i * 2] = (char)(v & 0xff);
		out[i * 2 + 1] = (char)((v >> 8) & 0xff);
	}

	/* an odd trailing byte is half a sample: a chunk boundary, not a
	 * sample to scale, so it goes through as it came.
	 */
	if (n & 1)
		out[n - 1] = p[n - 1];

	luaL_pushresultsize(&b, n);
	return 1;
}

static const luaL_Reg lib[] = {
	{ "gain", l_gain },
	{ NULL, NULL }
};

int luaopen_pcm_native(lua_State *L);

int
luaopen_pcm_native(lua_State *L)
{
	luaL_newlib(L, lib);
	return 1;
}
