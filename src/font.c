/* los.font: glyphs into a pixel rectangle, for whoever is drawing.
 *
 * Not part of los.platform.fb, on purpose. fb "knows rectangles, pixels
 * and a fill colour; it does not know what a window is, what a font is,
 * or who is drawing" -- so this is a separate mechanism, and the policy
 * (what text, where, in which colours) stays in lua. What comes back is
 * an ordinary BGRx rectangle of the kind fb.load already takes.
 *
 * In C because of where the data lives. The glyph table is 3072 bytes
 * of .rodata, mapped read-only and costing no RAM at all -- the same
 * reason embedfs is free. The same table as lua strings would be ~95
 * TString objects plus a table, several KB, in every proc that required
 * it. On esp32, where .rodata is flash and there is no PSRAM, that is
 * the scarce pool -- which is why this is C and not a lua module, on
 * every platform.
 */

#include <stddef.h>
#include <stdint.h>

#include "lauxlib.h"
#include "lua.h"

#include "font_spleen.h"

/* font.render(s, fg, bg) -> pixels, w, h
 *
 * fg and bg are 0xRRGGBB. The result is #s*FONT_W by FONT_H, four bytes
 * per pixel, ready for fb.load -- so drawing a line of text is one
 * render and one load rather than a call per glyph.
 */
static int
font_render(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);
	lua_Unsigned fg = (lua_Unsigned)luaL_checkinteger(L, 2);
	lua_Unsigned bg = (lua_Unsigned)luaL_optinteger(L, 3, 0);
	size_t w = n * FONT_W;
	size_t need = w * FONT_H * 4;
	luaL_Buffer b;
	unsigned char *out;
	size_t i, row, col;

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

	out = (unsigned char *)luaL_buffinitsize(L, &b, need);

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
				    out + ((row * w) + i * FONT_W + col) * 4;

				px[0] = (unsigned char)(c & 0xff);	 /* B */
				px[1] = (unsigned char)((c >> 8) & 0xff); /* G */
				px[2] = (unsigned char)((c >> 16) & 0xff);/* R */
				px[3] = 0;
			}
		}
	}
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
