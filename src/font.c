/* los.font: glyphs into a pixel rectangle of the kind fb.load takes.
 * Separate from los.platform.fb on purpose -- fb knows nothing of
 * fonts, so what text goes where stays in lua.
 */

/* In C because the glyph table is 3072 bytes of .rodata, costing no
 * RAM; as lua strings it would be ~95 TString objects in every proc
 * that required it, out of the pool esp32 has least of.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "buf.h"

#include "font_spleen.h"

/* 0xRRGGBB to the two big-endian bytes an r5g6b5 image holds, which is
 * also what an ST7789 takes on the wire. lib/memdraw.lua's pixel16 is
 * the same arithmetic.
 */
static unsigned short
to565(lua_Unsigned c)
{
	return (unsigned short)(((c >> 8) & 0xf800) | ((c >> 5) & 0x07e0) |
	    ((c >> 3) & 0x001f));
}

/* font.render(s, fg, bg, wantbuf, fmt) -> pixels, w, h. fg and bg are
 * 0xRRGGBB; fmt is "bgrx" (the default) or "r5g6b5" -- the
 * destination's own format, so nothing converts on the way.
 */
static int
font_render(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);
	lua_Unsigned fg = (lua_Unsigned)luaL_checkinteger(L, 2);
	lua_Unsigned bg = (lua_Unsigned)luaL_optinteger(L, 3, 0);
	int wantbuf = lua_toboolean(L, 4);
	const char *fmt = luaL_optstring(L, 5, "bgrx");
	int bpp = strcmp(fmt, "r5g6b5") == 0 ? 2 : 4;
	size_t w = n * FONT_W;
	size_t need = w * FONT_H * bpp;
	luaL_Buffer b;
	unsigned char *out;
	size_t i, row, col;

	if (bpp == 4 && strcmp(fmt, "bgrx") != 0)
		return luaL_error(L, "font.render: no such format: %s", fmt);

	if (n == 0) {
		lua_pushliteral(L, "");
		lua_pushinteger(L, 0);
		lua_pushinteger(L, FONT_H);
		return 3;
	}
	/* a ceiling rather than trust: the caller decides the string, and
	 * a long one would ask for a very large lua string on a machine
	 * that has not got it. 256 columns is past any screen here.
	 */
	if (n > 256)
		return luaL_error(L, "font.render: %d chars is too many",
		    (int)n);

	/* a buffer where the caller asked for one. Every byte is written
	 * below, so it is allocated rather than made: nothing to zero.
	 */
	if (wantbuf) {
		out = luabuf_push(L, need);
		if (!out)
			return luaL_error(L, "font.render: no room for %d "
			    "bytes", (int)need);
	} else {
		out = (unsigned char *)luaL_buffinitsize(L, &b, need);
	}

	for (row = 0; row < FONT_H; row++) {
		for (i = 0; i < n; i++) {
			uint8_t bits = font8x16[(unsigned char)s[i]][row];

			for (col = 0; col < FONT_W; col++) {
				/* the generator packs each row left-aligned
				 * in the byte, so the leftmost pixel is the
				 * high bit.
				 */
				lua_Unsigned c =
				    (bits & (0x80u >> col)) ? fg : bg;
				unsigned char *px =
				    out + ((row * w) + i * FONT_W + col) * bpp;

				if (bpp == 2) {
					unsigned short v = to565(c);

					px[0] = (unsigned char)(v >> 8);
					px[1] = (unsigned char)(v & 0xff);
					continue;
				}
				px[0] = (unsigned char)(c & 0xff);	 /* B */
				px[1] = (unsigned char)((c >> 8) & 0xff); /* G */
				px[2] = (unsigned char)((c >> 16) & 0xff);/* R */
				px[3] = 0;
			}
		}
	}
	if (!wantbuf)
		luaL_pushresultsize(&b, need);
	lua_pushinteger(L, (lua_Integer)w);
	lua_pushinteger(L, FONT_H);
	return 3;
}

/* font.size() -> w, h -- the cell, so a caller can work out how many
 * columns and rows a screen holds without knowing the font.
 */
static int
font_size(lua_State *L)
{
	lua_pushinteger(L, FONT_W);
	lua_pushinteger(L, FONT_H);
	return 2;
}

static const luaL_Reg fontlib[] = {
	{ "render", font_render },
	{ "size", font_size },
	{ NULL, NULL }
};

int luaopen_los_font(lua_State *L);

int
luaopen_los_font(lua_State *L)
{
	luaL_newlib(L, fontlib);
	return 1;
}
