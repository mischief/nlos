/* los.platform.fb: the raw framebuffer, and nothing above it.
 *
 * registered in package.preload ONLY for the one task holding PRIV_FB
 * (kernel.c's driver table spawns /task/fb.lua with it), exactly like
 * cons/wire/power in drivers.c. every other proc reaches pixels by
 * holding a send-right to that task.
 *
 * this is the bottom of two layers, deliberately. plan 9 splits the
 * same way: libmemdraw owns a Memimage and memload/memunload move raw
 * pixel rectangles in and out of it, and libmemlayer stacks windows on
 * top without the lower layer knowing anything about them. load() and
 * unload() below are that pair. a rio-shaped thing goes above, in lua,
 * and this file must never learn what a window is.
 *
 * everything here is a rectangle of BGRx bytes plus a fill. no drawing,
 * no fonts, no compositing, no damage tracking -- those have opinions.
 */

#include <stdlib.h>
#include <string.h>

#include "efi.h"
#include "platform.h"

#include "lua.h"
#include "lauxlib.h"
#include "buf.h"

static EFI_GUID gop_guid =
    { 0x9042a9de, 0x23dc, 0x4a38,
      { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } };

static EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;

/* probed once from kernel_init, before any proc exists -- same shape as
 * platform_have_p9/platform_have_eth, and the answer gates whether the
 * fb driver task is spawned at all.
 *
 * LocateProtocol is not in our trimmed EFI_BOOT_SERVICES, so this goes
 * the LocateHandleBuffer + HandleProtocol way that l_efi_locate already
 * uses. the FIRST handle wins: a machine with two GOPs (a real one and
 * a firmware-emulated one, which qemu -vga plus a passthrough card can
 * produce) gets whichever the firmware lists first, since choosing
 * between them is policy we have no basis for down here.
 */
int
platform_have_fb(void)
{
	EFI_HANDLE *handles = 0;
	UINTN count = 0;

	if (gop)
		return 1;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &gop_guid, 0, &count,
	    &handles) != EFI_SUCCESS || count == 0)
		return 0;

	if (BS->HandleProtocol(handles[0], &gop_guid, (void **)&gop) !=
	    EFI_SUCCESS)
		gop = 0;

	BS->FreePool(handles);
	return gop != 0;
}

int
efi_fb_size(UINTN *w, UINTN *h)
{
	if (!gop || !gop->Mode || !gop->Mode->Info) {
		*w = 0;
		*h = 0;
		return 0;
	}
	*w = gop->Mode->Info->HorizontalResolution;
	*h = gop->Mode->Info->VerticalResolution;
	return 1;
}

/* every entry point below re-checks. the module is unreachable without
 * PRIV_FB, but PRIV_FB does not by itself prove the probe succeeded --
 * kernel.c could grow a path that spawns the task anyway, and a null
 * deref in firmware context is not a diagnosable failure.
 */
static EFI_GRAPHICS_OUTPUT_PROTOCOL *
checkgop(lua_State *L)
{
	if (!gop)
		luaL_error(L, "no framebuffer");
	return gop;
}

/* the software cursor, defined below. Every op that touches the glass
 * lifts it first: what is saved underneath is only good until someone
 * draws there, and a read that included it would report the pointer as
 * part of the picture.
 */
static void cursor_hide(EFI_GRAPHICS_OUTPUT_PROTOCOL *g);
static void cursor_show(EFI_GRAPHICS_OUTPUT_PROTOCOL *g, int x, int y);
static int curshown, curx, cury;

#define CURSOR_LIFT(g)	int had_ = curshown; cursor_hide(g)
#define CURSOR_DROP(g)	do { if (had_) cursor_show(g, curx, cury); } while (0)

static const char *
formatname(EFI_GRAPHICS_PIXEL_FORMAT f)
{
	switch (f) {
	case PixelRedGreenBlueReserved8BitPerColor:
		return "rgbx";
	case PixelBlueGreenRedReserved8BitPerColor:
		return "bgrx";
	case PixelBitMask:
		return "bitmask";
	case PixelBltOnly:
		return "bltonly";
	default:
		return "unknown";
	}
}

/* push {n=, w=, h=, format=} for one mode. format is reported but is
 * NOT the caller's problem: Blt always speaks BGRx. it is here because
 * "bltonly" tells you there is no linear framebuffer behind this at
 * all, which is worth being able to see from the repl.
 */
static void
pushmode(lua_State *L, UINT32 n, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info)
{
	lua_createtable(L, 0, 4);
	lua_pushinteger(L, n);
	lua_setfield(L, -2, "n");
	lua_pushinteger(L, info->HorizontalResolution);
	lua_setfield(L, -2, "w");
	lua_pushinteger(L, info->VerticalResolution);
	lua_setfield(L, -2, "h");
	lua_pushstring(L, formatname(info->PixelFormat));
	lua_setfield(L, -2, "format");
}

/* fb.modes() -> { {n=,w=,h=,format=}, ... } */
static int
l_modes(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	UINT32 i;

	lua_createtable(L, (int)g->Mode->MaxMode, 0);
	for (i = 0; i < g->Mode->MaxMode; i++) {
		EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = 0;
		UINTN size = 0;

		/* a mode that fails QueryMode is skipped rather than
		 * fatal: MaxMode counts modes the firmware admits to, and
		 * a hole in that range is the firmware's bug, not ours.
		 * the returned table is keyed by array position, and each
		 * entry carries its own .n, so a hole does not shift the
		 * meaning of anything.
		 */
		if (g->QueryMode(g, i, &size, &info) != EFI_SUCCESS)
			continue;
		pushmode(L, i, info);
		lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
	}
	return 1;
}

/* fb.mode() -> {n=,w=,h=,format=} for the mode in force now */
static int
l_mode(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);

	pushmode(L, g->Mode->Mode, g->Mode->Info);
	return 1;
}

/* fb.setmode(n)
 *
 * SetMode resets ConOut. our real console is the serial line, so that
 * costs us nothing here -- but anything watching the firmware's own
 * text console goes quiet after this call, which has surprised at
 * least one person per operating system.
 */
static int
l_setmode(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	UINT32 n = (UINT32)luaL_checkinteger(L, 1);

	if (n >= g->Mode->MaxMode)
		return luaL_error(L, "no such mode: %d", (int)n);
	if (g->SetMode(g, n) != EFI_SUCCESS)
		return luaL_error(L, "setmode %d failed", (int)n);
	return 0;
}

/* clip a rectangle to the screen, raising rather than letting the
 * firmware read or write past the end of the framebuffer. Blt is
 * specified to reject an out-of-range rectangle, but "specified to"
 * and "does" are different claims about firmware, and the buffer whose
 * size depends on this is ours.
 */
static void
checkrect(lua_State *L, lua_Integer x, lua_Integer y, lua_Integer w,
    lua_Integer h)
{
	EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gop->Mode->Info;

	if (w < 0 || h < 0)
		luaL_error(L, "negative rectangle %dx%d", (int)w, (int)h);
	if (x < 0 || y < 0)
		luaL_error(L, "negative origin %d,%d", (int)x, (int)y);
	if (x + w > (lua_Integer)info->HorizontalResolution ||
	    y + h > (lua_Integer)info->VerticalResolution)
		luaL_error(L, "rectangle %d,%d %dx%d is off a %dx%d screen",
		    (int)x, (int)y, (int)w, (int)h,
		    (int)info->HorizontalResolution,
		    (int)info->VerticalResolution);
}

/* fb.fill(x, y, w, h, color) -- color is 0xRRGGBB
 *
 * EfiBltVideoFill needs one pixel, not a rectangle of them, so this is
 * here rather than in lua for a real reason and not for speed alone:
 * expressing it as load() means building and copying w*h*4 bytes to say
 * something the firmware can do from four.
 */
static int
l_fill(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	lua_Unsigned c = (lua_Unsigned)luaL_checkinteger(L, 5);
	EFI_GRAPHICS_OUTPUT_BLT_PIXEL px;

	checkrect(L, x, y, w, h);

	px.Red = (UINT8)(c >> 16);
	px.Green = (UINT8)(c >> 8);
	px.Blue = (UINT8)c;
	px.Reserved = 0;

	if (w == 0 || h == 0)
		return 0;

	CURSOR_LIFT(g);
	if (g->Blt(g, &px, EfiBltVideoFill, 0, 0, (UINTN)x, (UINTN)y,
	    (UINTN)w, (UINTN)h, 0) != EFI_SUCCESS) {
		CURSOR_DROP(g);
		return luaL_error(L, "fill failed");
	}
	CURSOR_DROP(g);
	return 0;
}

/* fb.load(x, y, w, h, pixels) -- plan 9's memload: raw pixel rectangle
 * in. pixels is w*h*4 bytes of BGRx, row-major, no padding.
 *
 * the string is copied into a pool buffer rather than handed to Blt
 * directly. a lua string is not guaranteed 4-byte aligned and the
 * firmware will happily do aligned loads out of it; the copy is also
 * what lets us reject a short string before the firmware reads past
 * its end.
 */
static int
l_load(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	size_t n;
	const char *pix = luabuf_check(L, 5, &n);
	/* Blt speaks BGRx and nothing else, so this refuses rather than
	 * converts: a client asks the screen what it takes.
	 */
	const char *fmt = luaL_optstring(L, 6, "bgrx");
	size_t need = (size_t)w * (size_t)h * 4;
	void *buf = 0;
	EFI_STATUS st;

	if (strcmp(fmt, "bgrx") != 0)
		return luaL_error(L, "fb.load: this screen takes bgrx, "
		    "not %s", fmt);
	checkrect(L, x, y, w, h);
	if (n != need)
		return luaL_error(L,
		    "want %d bytes for %dx%d, got %d",
		    (int)need, (int)w, (int)h, (int)n);
	if (need == 0)
		return 0;

	if (BS->AllocatePool(EfiLoaderData, need, &buf) != EFI_SUCCESS)
		return luaL_error(L, "out of memory for %d bytes", (int)need);
	memcpy(buf, pix, need);

	CURSOR_LIFT(g);
	st = g->Blt(g, buf, EfiBltBufferToVideo, 0, 0, (UINTN)x, (UINTN)y,
	    (UINTN)w, (UINTN)h, 0);
	BS->FreePool(buf);
	CURSOR_DROP(g);

	if (st != EFI_SUCCESS)
		return luaL_error(L, "load failed");
	return 0;
}

/* fb.unload(x, y, w, h) -> pixels -- plan 9's memunload: raw pixel
 * rectangle out, same BGRx layout as load().
 *
 * readback is not a curiosity. it is the entire in-band test story for
 * this module (fill a rect, read it back, compare) and it is what a
 * layer above needs to save the parts of the screen a window covers --
 * libmemlayer's Memlayer.save, exactly.
 */
static int
l_unload(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	size_t need = (size_t)w * (size_t)h * 4;
	void *buf = 0;
	EFI_STATUS st;

	checkrect(L, x, y, w, h);
	if (need == 0) {
		lua_pushliteral(L, "");
		return 1;
	}

	if (BS->AllocatePool(EfiLoaderData, need, &buf) != EFI_SUCCESS)
		return luaL_error(L, "out of memory for %d bytes", (int)need);

	CURSOR_LIFT(g);
	st = g->Blt(g, buf, EfiBltVideoToBltBuffer, (UINTN)x, (UINTN)y, 0, 0,
	    (UINTN)w, (UINTN)h, 0);
	CURSOR_DROP(g);
	if (st == EFI_SUCCESS)
		lua_pushlstring(L, buf, need);
	BS->FreePool(buf);

	if (st != EFI_SUCCESS)
		return luaL_error(L, "unload failed");
	return 1;
}

/* fb.scroll(sx, sy, dx, dy, w, h) -- EfiBltVideoToVideo.
 *
 * on-screen copy, which the firmware can do without the rectangle ever
 * crossing into our address space. a terminal scrolling by a line is
 * the whole reason it exists; without it that is an unload plus a load
 * of the same megabyte, through the serializer if the two ends are
 * different procs.
 */
static int
l_scroll(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	lua_Integer sx = luaL_checkinteger(L, 1);
	lua_Integer sy = luaL_checkinteger(L, 2);
	lua_Integer dx = luaL_checkinteger(L, 3);
	lua_Integer dy = luaL_checkinteger(L, 4);
	lua_Integer w = luaL_checkinteger(L, 5);
	lua_Integer h = luaL_checkinteger(L, 6);

	checkrect(L, sx, sy, w, h);
	checkrect(L, dx, dy, w, h);
	if (w == 0 || h == 0)
		return 0;

	if (g->Blt(g, 0, EfiBltVideoToVideo, (UINTN)sx, (UINTN)sy, (UINTN)dx,
	    (UINTN)dy, (UINTN)w, (UINTN)h, 0) != EFI_SUCCESS)
		return luaL_error(L, "scroll failed");
	return 0;
}

/* ---- the pointer, drawn in software ----
 *
 * The panel's is the display controller's; this screen has none, so it
 * is composited here: save what is under it, draw over the copy, put
 * the saved pixels back before moving.
 */
/* a crosshair, as the panel draws: the arms cross on the hotspot, so
 * the point is visible rather than covered by the cursor's own body.
 */
#define CURSOR_R	5
#define CURSOR_SIDE	(2 * CURSOR_R + 1)
#define CURSOR_INK	0x0000ff00	/* green, over dark text */

static UINT32 curunder[CURSOR_SIDE * CURSOR_SIDE];

/* the rectangle actually saved. A cursor at an edge is clipped, and
 * Blt refuses one that leaves the screen.
 */
static int curox, curoy, curw, curh;

static void
cursor_hide(EFI_GRAPHICS_OUTPUT_PROTOCOL *g)
{
	if (!curshown)
		return;
	g->Blt(g, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)curunder,
	    EfiBltBufferToVideo, 0, 0, (UINTN)curox, (UINTN)curoy,
	    (UINTN)curw, (UINTN)curh, 0);
	curshown = 0;
}

static void
cursor_show(EFI_GRAPHICS_OUTPUT_PROTOCOL *g, int x, int y)
{
	UINT32 img[CURSOR_SIDE * CURSOR_SIDE];
	UINTN sw = g->Mode->Info->HorizontalResolution;
	UINTN sh = g->Mode->Info->VerticalResolution;
	int i, j, x1, y1;

	if (x < 0 || y < 0 || (UINTN)x >= sw || (UINTN)y >= sh)
		return;

	curox = x - CURSOR_R < 0 ? 0 : x - CURSOR_R;
	curoy = y - CURSOR_R < 0 ? 0 : y - CURSOR_R;
	x1 = (UINTN)(x + CURSOR_R + 1) > sw ? (int)sw : x + CURSOR_R + 1;
	y1 = (UINTN)(y + CURSOR_R + 1) > sh ? (int)sh : y + CURSOR_R + 1;
	curw = x1 - curox;
	curh = y1 - curoy;
	if (curw <= 0 || curh <= 0)
		return;

	if (g->Blt(g, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)curunder,
	    EfiBltVideoToBltBuffer, (UINTN)curox, (UINTN)curoy, 0, 0,
	    (UINTN)curw, (UINTN)curh, 0) != EFI_SUCCESS)
		return;

	for (j = 0; j < curh; j++)
		for (i = 0; i < curw; i++)
			img[j * curw + i] =
			    (curoy + j == y || curox + i == x) ?
			    CURSOR_INK : curunder[j * curw + i];

	curx = x;
	cury = y;
	curshown = 1;
	g->Blt(g, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)img, EfiBltBufferToVideo,
	    0, 0, (UINTN)curox, (UINTN)curoy, (UINTN)curw, (UINTN)curh, 0);
}

/* fb.cursor(x, y, on): move, show or hide. An absent coordinate leaves
 * it where it was, which is what a bare show or hide is.
 */
static int
l_cursor(lua_State *L)
{
	EFI_GRAPHICS_OUTPUT_PROTOCOL *g = checkgop(L);
	int x = (int)luaL_optinteger(L, 1, curx);
	int y = (int)luaL_optinteger(L, 2, cury);
	int on = lua_isnoneornil(L, 3) ? curshown : lua_toboolean(L, 3);

	cursor_hide(g);
	if (on)
		cursor_show(g, x, y);
	else {
		curx = x;
		cury = y;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg fblib[] = {
	{ "cursor", l_cursor },
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
