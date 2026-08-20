/* los.platform.fb, and the keyboard and pointer that come with it. The
 * pixels stay in our memory and the host reads them from there, which
 * is what makes them readable as well as writable -- and lib/draw
 * reads. No lock: one cpu, one thread of control.
 */

#include <stdlib.h>
#include <string.h>

#include "buf.h"
#include "host.h"
#include "kernel.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"
#include "wasm.h"

/* how often the screen is presented, at most. Every fill and load marks
 * damage and returns; presenting on each would put a frame's wait in
 * the middle of a redraw made of a hundred small blits.
 */
#define FRAME_US 16000

/* the screen, as bytes: BGRx, the same layout gop.c and the hosted
 * window hand up, so lib/draw needs no branch.
 */
static unsigned char *shadow;
static int fbw, fbh;

static int dirty;
static unsigned long long lastframe;

/* the damaged rectangle, as bounds rather than a list: a redraw is many
 * small blits and their union is nearly always what has to be painted.
 */
static int dx0, dy0, dx1, dy1;

static void
damage(int x, int y, int w, int h)
{
	if (!dirty) {
		dx0 = x;
		dy0 = y;
		dx1 = x + w;
		dy1 = y + h;
		dirty = 1;
		return;
	}
	if (x < dx0)
		dx0 = x;
	if (y < dy0)
		dy0 = y;
	if (x + w > dx1)
		dx1 = x + w;
	if (y + h > dy1)
		dy1 = y + h;
}

void
fb_flush(void)
{
	unsigned long long now;

	if (!shadow || !dirty)
		return;
	now = platform_ticks() / 1000ULL;
	if (now - lastframe < FRAME_US)
		return;
	lastframe = now;
	dirty = 0;
	host_fb_flush(dx0, dy0, dx1 - dx0, dy1 - dy0);
}

int
fb_open(int w, int h)
{
	if (w <= 0 || h <= 0)
		return -1;
	shadow = calloc((size_t)w * h, 4);
	if (!shadow) {
		kernel_say("fb: no room for the screen");
		return -1;
	}
	if (!host_fb_open(w, h, shadow)) {
		free(shadow);
		shadow = NULL;
		kernel_say("fb: the host opened no screen");
		return -1;
	}
	fbw = w;
	fbh = h;
	damage(0, 0, w, h);
	fb_flush();
	return 0;
}

int
platform_have_fb(void)
{
	return shadow != NULL;
}

int
platform_have_kbd(void)
{
	return shadow != NULL;
}

int
platform_kbd_read(void)
{
	return shadow ? host_kbd() : -1;
}

int
platform_have_ptr(void)
{
	return shadow != NULL;
}

/* state, not a queue: a pointer's past positions are of no use to a
 * reader that has fallen behind -- see platform.h.
 */
int
platform_ptr_read(int *x, int *y, int *buttons)
{
	return shadow ? host_ptr(x, y, buttons) : 0;
}

static void
checkrect(lua_State *L, lua_Integer x, lua_Integer y, lua_Integer w,
    lua_Integer h)
{
	if (w < 0 || h < 0)
		luaL_error(L, "negative rectangle %dx%d", (int)w, (int)h);
	if (x < 0 || y < 0)
		luaL_error(L, "negative origin %d,%d", (int)x, (int)y);
	if (x + w > fbw || y + h > fbh)
		luaL_error(L, "rectangle %d,%d %dx%d is off a %dx%d screen",
		    (int)x, (int)y, (int)w, (int)h, fbw, fbh);
}

static void
pushmode(lua_State *L)
{
	lua_createtable(L, 0, 4);
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "n");
	lua_pushinteger(L, fbw);
	lua_setfield(L, -2, "w");
	lua_pushinteger(L, fbh);
	lua_setfield(L, -2, "h");
	lua_pushstring(L, "bgrx");
	lua_setfield(L, -2, "format");
}

static int
l_mode(lua_State *L)
{
	pushmode(L);
	return 1;
}

/* one mode, which is the canvas this was started with. */
static int
l_modes(lua_State *L)
{
	lua_createtable(L, 1, 0);
	pushmode(L);
	lua_rawseti(L, -2, 1);
	return 1;
}

static int
l_setmode(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);

	if (n != 0)
		return luaL_error(L, "no such mode: %d", (int)n);
	return 0;
}

static int
l_fill(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	lua_Integer color = luaL_checkinteger(L, 5);
	unsigned char px[4];

	checkrect(L, x, y, w, h);
	px[0] = (unsigned char)(color & 0xff);		/* blue */
	px[1] = (unsigned char)((color >> 8) & 0xff);	/* green */
	px[2] = (unsigned char)((color >> 16) & 0xff);	/* red */
	px[3] = 0;

	for (lua_Integer row = 0; row < h; row++) {
		unsigned char *p = shadow + ((y + row) * fbw + x) * 4;

		for (lua_Integer col = 0; col < w; col++, p += 4)
			memcpy(p, px, 4);
	}
	damage((int)x, (int)y, (int)w, (int)h);

	lua_pushboolean(L, 1);
	return 1;
}

static int
l_load(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	size_t n;
	const char *pixels = luabuf_check(L, 5, &n);
	/* the screen takes BGRx and nothing else, so this refuses rather
	 * than converts: a client asks the screen what it takes.
	 */
	const char *fmt = luaL_optstring(L, 6, "bgrx");

	if (strcmp(fmt, "bgrx") != 0)
		return luaL_error(L, "fb.load: this screen takes bgrx, "
		    "not %s", fmt);
	checkrect(L, x, y, w, h);
	if (n != (size_t)(w * h * 4))
		return luaL_error(L, "want %d bytes for %dx%d, got %d",
		    (int)(w * h * 4), (int)w, (int)h, (int)n);
	for (lua_Integer row = 0; row < h; row++)
		memcpy(shadow + ((y + row) * fbw + x) * 4,
		    pixels + row * w * 4, (size_t)w * 4);
	damage((int)x, (int)y, (int)w, (int)h);

	lua_pushboolean(L, 1);
	return 1;
}

static int
l_unload(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);

	/* "rgb" narrows here rather than in the task above, which is the
	 * point of the driver knowing the format: the channels are already
	 * eight bits wide, so dropping the pad costs nothing.
	 */
	const char *fmt = luaL_optstring(L, 5, "bgrx");
	int bpp = strcmp(fmt, "rgb") == 0 ? 3 : 4;
	luaL_Buffer b;

	checkrect(L, x, y, w, h);
	if (w == 0 || h == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	char *out = luaL_buffinitsize(L, &b, (size_t)w * h * bpp);

	for (lua_Integer row = 0; row < h; row++) {
		const unsigned char *src = shadow + ((y + row) * fbw + x) * 4;

		if (bpp == 4) {
			memcpy(out + row * w * 4, src, (size_t)w * 4);
			continue;
		}
		for (lua_Integer col = 0; col < w; col++) {
			char *p = out + (row * w + col) * 3;

			p[0] = (char)src[col * 4 + 2];	/* red */
			p[1] = (char)src[col * 4 + 1];	/* green */
			p[2] = (char)src[col * 4 + 0];	/* blue */
		}
	}

	luaL_pushresultsize(&b, (size_t)w * h * bpp);
	return 1;
}

/* memmove per row, and rows in the order that survives an overlap: a
 * scroll is the one operation whose source and destination are the same
 * buffer.
 */
static int
l_scroll(lua_State *L)
{
	lua_Integer sx = luaL_checkinteger(L, 1);
	lua_Integer sy = luaL_checkinteger(L, 2);
	lua_Integer dx = luaL_checkinteger(L, 3);
	lua_Integer dy = luaL_checkinteger(L, 4);
	lua_Integer w = luaL_checkinteger(L, 5);
	lua_Integer h = luaL_checkinteger(L, 6);

	checkrect(L, sx, sy, w, h);
	checkrect(L, dx, dy, w, h);

	if (dy <= sy)
		for (lua_Integer row = 0; row < h; row++)
			memmove(shadow + ((dy + row) * fbw + dx) * 4,
			    shadow + ((sy + row) * fbw + sx) * 4,
			    (size_t)w * 4);
	else
		for (lua_Integer row = h - 1; row >= 0; row--)
			memmove(shadow + ((dy + row) * fbw + dx) * 4,
			    shadow + ((sy + row) * fbw + sx) * 4,
			    (size_t)w * 4);
	damage((int)dx, (int)dy, (int)w, (int)h);

	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg fblib[] = {
	{ "modes", l_modes },
	{ "mode", l_mode },
	{ "setmode", l_setmode },
	{ "fill", l_fill },
	{ "load", l_load },
	{ "unload", l_unload },
	{ "scroll", l_scroll },
	{ NULL, NULL }
};

int luaopen_los_platform_fb(lua_State *L);

int
luaopen_los_platform_fb(lua_State *L)
{
	luaL_newlib(L, fblib);
	return 1;
}
