/* los.crc -- the two check polynomials lib/zmodem.lua runs over every
 * byte it sends or receives.
 *
 * Here for the same reason as the internet checksum in inet.c, and by
 * the same test: a CRC is not a decision. The polynomials are fixed by
 * Forsberg's zmodem.h, they are the same for every frame, and they are
 * the only thing on the path whose cost grows with the payload.
 * Everything with an opinion -- framing, escaping, when to ask for a
 * retransmit, what a window is -- stays in Lua.
 *
 * Measured in the guest over a 1MiB string, table-driven Lua against
 * this:
 *
 *	           Lua      C
 *	crc32    96ms    2ms
 *	crc16   110ms    2ms
 *
 * A transfer runs the data through once at each end, so on the 256KiB
 * two-proc transfer in test/boot/test_zmodem.lua that was 48ms of 128ms
 * -- 37% of the whole thing, in five lines of arithmetic.
 *
 * These are *update* primitives: seed in, running value out, no
 * initialisation and no final complement. That is deliberate. ZMODEM
 * checks a frame by running the received check bytes through the same
 * function and comparing against a residue, which needs the raw
 * register rather than a finished value, and CRC32's complement is the
 * caller's business either way. lib/zmodem.lua keeps its own Lua
 * implementation and prefers this when it is there, so the host tests
 * -- which run the same module under an ordinary lua5.4 with no kernel
 * anywhere -- get the same answers more slowly. test/host_zmodem.lua's
 * check vectors are what keeps the two honest.
 */

#include <stddef.h>

#include "buf.h"
#include "lua.h"
#include "lauxlib.h"

static unsigned short crc16tab[256];
static unsigned int crc32tab[256];
static int tabsdone;

static void
mktabs(void)
{
	int i, j;

	for (i = 0; i < 256; i++) {
		unsigned int c = (unsigned int)i << 8;

		for (j = 0; j < 8; j++)
			c = (c & 0x8000) ? ((c << 1) ^ 0x1021) : (c << 1);
		crc16tab[i] = (unsigned short)c;
	}
	for (i = 0; i < 256; i++) {
		unsigned int c = (unsigned int)i;

		for (j = 0; j < 8; j++)
			c = (c & 1) ? ((c >> 1) ^ 0xedb88320u) : (c >> 1);
		crc32tab[i] = c;
	}
	tabsdone = 1;
}

/* CCITT, unreflected, data xored into the table index -- CRC-16/XMODEM,
 * 0x31c3 over "123456789". The equivalent augmented form (data xored in
 * at the low end, two zero bytes fed through before use) reaches the
 * same value by a different route; the two are not interchangeable
 * half-and-half.
 */
static int
l_crc16(lua_State *L)
{
	size_t n = 0;
	const char *s = luabuf_check(L, 1, &n);
	const unsigned char *p = (const unsigned char *)s;
	unsigned int crc = (unsigned int)luaL_optinteger(L, 2, 0) & 0xffff;
	size_t i;

	for (i = 0; i < n; i++)
		crc = ((crc << 8) ^ crc16tab[((crc >> 8) ^ p[i]) & 0xff]) &
		    0xffff;

	lua_pushinteger(L, (lua_Integer)crc);
	return 1;
}

/* the ordinary reflected CRC32, seeded 0xffffffff by default and
 * returned uncomplemented.
 */
static int
l_crc32(lua_State *L)
{
	size_t n = 0;
	const char *s = luabuf_check(L, 1, &n);
	const unsigned char *p = (const unsigned char *)s;
	unsigned int crc = (unsigned int)luaL_optinteger(L, 2, 0xffffffff);
	size_t i;

	for (i = 0; i < n; i++)
		crc = (crc >> 8) ^ crc32tab[(crc ^ p[i]) & 0xff];

	lua_pushinteger(L, (lua_Integer)crc);
	return 1;
}

/* unzdle(s, pos) -- decode one run of ZDLE-escaped data. Returns data,
 * terminator, nextpos at a subpacket terminator, and data, nil, nextpos
 * when the input runs out first -- so the caller feeds more and calls
 * again. nil, "bad escape" for an escape that means nothing here.
 */
#define ZDLE	0x18
#define ZRUB0	0x6c
#define ZRUB1	0x6d

static int
l_unzdle(lua_State *L)
{
	size_t n = 0;
	const char *s = luaL_checklstring(L, 1, &n);
	const unsigned char *p = (const unsigned char *)s;
	size_t i = (size_t)luaL_checkinteger(L, 2) - 1;
	luaL_Buffer b;

	luaL_buffinit(L, &b);
	while (i < n) {
		unsigned char c = p[i];
		size_t run;

		if (c != ZDLE) {
			/* the plain run to the next escape, in one copy. */
			for (run = i; run < n && p[run] != ZDLE; run++)
				;
			luaL_addlstring(&b, s + i, run - i);
			i = run;
			continue;
		}
		if (i + 1 >= n)
			break;		/* the escaped byte is not here yet */
		c = p[i + 1];
		if (c >= 0x68 && c <= 0x6b) {
			luaL_pushresult(&b);
			lua_pushinteger(L, (lua_Integer)c);
			lua_pushinteger(L, (lua_Integer)(i + 3));
			return 3;
		}
		if (c == ZRUB0)
			luaL_addchar(&b, (char)0x7f);
		else if (c == ZRUB1)
			luaL_addchar(&b, (char)0xff);
		else if ((c & 0x60) == 0x40)
			luaL_addchar(&b, (char)(c ^ 0x40));
		else {
			lua_pushnil(L);
			lua_pushstring(L, "bad escape");
			return 2;
		}
		i += 2;
	}
	luaL_pushresult(&b);
	lua_pushnil(L);
	lua_pushinteger(L, (lua_Integer)(i + 1));
	return 3;
}

static const luaL_Reg crclib[] = {
	{ "crc16", l_crc16 },
	{ "crc32", l_crc32 },
	{ "unzdle", l_unzdle },
	{ NULL, NULL },
};

int	luaopen_los_crc(lua_State *L);

int
luaopen_los_crc(lua_State *L)
{
	if (!tabsdone)
		mktabs();
	luaL_newlib(L, crclib);
	return 1;
}
