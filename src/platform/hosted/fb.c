/* los.platform.fb, and the keyboard and pointer that come with it: a
 * window on the host's desktop, through SDL. The pixels live in our
 * memory and the texture is a copy pushed at it, which is what makes
 * readback possible at all -- a display whose pixels are only on the
 * far side of a driver can be written but not read.
 */

#include <stdlib.h>
#include <string.h>

#include "buf.h"
#include "lock.h"
#include "hosted.h"
#include "kernel.h"
#include "lauxlib.h"
#include "lua.h"
#include "platform.h"

#ifdef HAVE_SDL

#include <SDL2/SDL.h>

/* how often the window is repainted, at most. Every fill and load marks
 * damage and returns; presenting on each one would put a frame's wait
 * in the middle of a redraw made of a hundred small blits.
 */
#define FRAME_US 16000

static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *texture;

/* the screen, as bytes: BGRx, which is SDL_PIXELFORMAT_RGB888 on a
 * little-endian machine -- the pad is what that name leaves out -- and
 * the same layout gop.c hands up. One name for it either way, so
 * lib/draw and the tests need no branch.
 */
static unsigned char *shadow;
static int fbw, fbh;

static int dirty;
static unsigned long long lastframe;

/* the screen and the input queues both: the task owning the device runs
 * on whichever cpu took it, the pumps on whichever reached the idle
 * path. One lock, because a display is not contended and a second would
 * only add an order to get wrong. Nothing raises while holding it -- a
 * lua error would leave it held.
 */
static struct lock fblock = LOCK_INIT;

/* keys, as a ring: the guest reads one character per call and a burst
 * of typing must not be lost between reads.
 */
#define KEYRING 256

static unsigned char keys[KEYRING];
static int keyhead, keytail;

static int ptrx, ptry, ptrbuttons, ptrmoved;

/* A press and a release inside one poll window are the whole of a
 * click, and the state they leave behind says nothing happened. Every
 * button edge is kept; positions stay state, and may be dropped.
 */
#define BUTRING 32

static struct butevent {
	int x, y, buttons;
} butring[BUTRING];
static int buthead, buttail;

static void
butpush(void)
{
	int next = (buttail + 1) % BUTRING;

	/* full: overwrite the newest rather than shed the oldest, so
	 * what a reader ends up holding is still the state that is.
	 */
	if (next == buthead)
		buttail = (buttail + BUTRING - 1) % BUTRING;
	butring[buttail].x = ptrx;
	butring[buttail].y = ptry;
	butring[buttail].buttons = ptrbuttons;
	buttail = (buttail + 1) % BUTRING;
}

static void
keypush(int c)
{
	int next = (keytail + 1) % KEYRING;

	if (next == keyhead)
		return;			/* full: drop, rather than wrap onto unread */
	keys[keytail] = (unsigned char)c;
	keytail = next;
}

/* what a terminal sends, because that is what the console line editor
 * on the other end of this was written against.
 */
static void
keydown(SDL_Keycode key, SDL_Keymod mod)
{
	if (mod & KMOD_CTRL) {
		if (key >= 'a' && key <= 'z')
			keypush(key - 'a' + 1);
		return;
	}
	switch (key) {
	case SDLK_RETURN:
	case SDLK_KP_ENTER:
		keypush('\r');
		break;
	case SDLK_BACKSPACE:
		keypush(0x7f);
		break;
	case SDLK_ESCAPE:
		keypush(0x1b);
		break;
	case SDLK_TAB:
		keypush('\t');
		break;
	/* the arrows as the escape sequences a vt100 sends: lib/readline
	 * already reads those from the serial line.
	 */
	case SDLK_UP:
	case SDLK_DOWN:
	case SDLK_RIGHT:
	case SDLK_LEFT:
		keypush(0x1b);
		keypush('[');
		keypush(key == SDLK_UP ? 'A' : key == SDLK_DOWN ? 'B' :
		    key == SDLK_RIGHT ? 'C' : 'D');
		break;
	default:
		break;
	}
}

/* SDL scales a mouse event through the renderer's logical size before
 * it hands it over, so what arrives is already in the guest's
 * coordinates. Only the bars a letterbox leaves need dealing with:
 * a point in one is outside the screen, and belongs at its edge.
 */
static void
ptrpos(int wx, int wy)
{
	ptrx = wx;
	ptry = wy;
	if (ptrx < 0)
		ptrx = 0;
	if (ptry < 0)
		ptry = 0;
	if (ptrx >= fbw)
		ptrx = fbw - 1;
	if (ptry >= fbh)
		ptry = fbh - 1;
}

static int
buttonbit(int b)
{
	switch (b) {
	case SDL_BUTTON_LEFT:
		return 1;
	case SDL_BUTTON_MIDDLE:
		return 2;
	case SDL_BUTTON_RIGHT:
		return 4;
	}
	return 0;
}

/* drain the host's events. Called from the reads below and from the
 * idle wait, so a window stays answerable whether the machine is busy
 * or asleep.
 */
static void
pump_locked(void)
{
	SDL_Event e;

	if (!window)
		return;
	while (SDL_PollEvent(&e)) {
		switch (e.type) {
		case SDL_QUIT:
			/* closing the window is this machine's power switch:
			 * there is no other way to ask a guest with no
			 * console of its own to stop.
			 */
			machine_halt();
			break;
		case SDL_KEYDOWN:
			keydown(e.key.keysym.sym, e.key.keysym.mod);
			break;
		case SDL_TEXTINPUT:
			for (const char *p = e.text.text; *p; p++)
				keypush((unsigned char)*p);
			break;
		/* every window event arrives under this one type, with
		 * the reason in a field rather than in the type, so
		 * the reasons need a switch of their own.
		 */
		case SDL_WINDOWEVENT:
			switch (e.window.event) {
			case SDL_WINDOWEVENT_CLOSE:
				machine_halt();
				break;
			/* the host asking for the screen back: uncovered,
			 * resized, unminimised. Nothing in the guest has
			 * changed, so only a repaint is owed -- and without
			 * this the window keeps whatever the compositor last
			 * had, which is usually black.
			 */
			case SDL_WINDOWEVENT_EXPOSED:
			case SDL_WINDOWEVENT_RESIZED:
			case SDL_WINDOWEVENT_SIZE_CHANGED:
			case SDL_WINDOWEVENT_SHOWN:
			case SDL_WINDOWEVENT_RESTORED:
				dirty = 1;
				lastframe = 0;	/* now, not next frame */
				break;
			default:
				break;
			}
			break;
		case SDL_MOUSEMOTION:
			ptrpos(e.motion.x, e.motion.y);
			ptrmoved = 1;
			break;
		case SDL_MOUSEBUTTONDOWN:
			ptrpos(e.button.x, e.button.y);
			ptrbuttons |= buttonbit(e.button.button);
			butpush();
			break;
		case SDL_MOUSEBUTTONUP:
			ptrpos(e.button.x, e.button.y);
			ptrbuttons &= ~buttonbit(e.button.button);
			butpush();
			break;
		default:
			break;
		}
	}
}

/* push the damaged screen at the window, at most one frame's worth of
 * often. The whole texture goes: the damage is tracked as a flag rather
 * than a rectangle because SDL uploads a full 1024x768 in well under
 * the frame time, and a union of rectangles is a thing to get wrong.
 */
static void
flush_locked(void)
{
	unsigned long long now;

	if (!window || !dirty)
		return;
	now = hosted_now_us();
	if (now - lastframe < FRAME_US)
		return;
	lastframe = now;
	dirty = 0;
	SDL_UpdateTexture(texture, NULL, shadow, fbw * 4);
	SDL_RenderClear(renderer);
	SDL_RenderCopy(renderer, texture, NULL, NULL);
	SDL_RenderPresent(renderer);
}

void
fb_pump(void)
{
	if (!window)
		return;
	lock(&fblock);
	pump_locked();
	unlock(&fblock);
}

void
fb_flush(void)
{
	if (!window)
		return;
	lock(&fblock);
	flush_locked();
	unlock(&fblock);
}

int
fb_open(int w, int h)
{
	/* zero is success here, and a negative is the failure: the
	 * truthiness of this call is the opposite of what it reads as.
	 */
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		kernel_say("fb: SDL_Init failed");
		return -1;
	}
	window = SDL_CreateWindow("lua-os", SDL_WINDOWPOS_UNDEFINED,
	    SDL_WINDOWPOS_UNDEFINED, w, h, SDL_WINDOW_RESIZABLE);
	if (!window) {
		kernel_say("fb: no window");
		return -1;
	}
	/* software, not whatever SDL would pick. The pixels are already in
	 * our memory and go up as one texture, so a GPU buys nothing --
	 * and an OpenGL context maps far more address space than this
	 * machine's -m ceiling allows, which fails as a GLX error from a
	 * driver rather than as anything about memory.
	 */
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
	if (!renderer) {
		kernel_say("fb: no renderer");
		return -1;
	}
	texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB888,
	    SDL_TEXTUREACCESS_STREAMING, w, h);
	if (!texture) {
		kernel_say("fb: no texture");
		return -1;
	}
	shadow = calloc((size_t)w * h, 4);
	if (!shadow) {
		kernel_say("fb: no room for the screen");
		return -1;
	}
	fbw = w;
	fbh = h;

	/* the screen keeps the size it booted with however the window is
	 * dragged: a mode change is the guest's to make, not the window
	 * manager's. Letterboxed rather than stretched, so a resize
	 * cannot quietly change the aspect the guest is drawing for.
	 */
	SDL_RenderSetLogicalSize(renderer, w, h);
	SDL_StartTextInput();
	dirty = 1;
	fb_flush();
	return 0;
}

int
platform_have_fb(void)
{
	return window != NULL;
}

int
platform_have_kbd(void)
{
	return window != NULL;
}

int
platform_kbd_read(void)
{
	int c = -1;

	if (!window)
		return -1;
	lock(&fblock);
	pump_locked();
	flush_locked();
	if (keyhead != keytail) {
		c = keys[keyhead];
		keyhead = (keyhead + 1) % KEYRING;
	}
	unlock(&fblock);
	return c;
}

int
platform_have_ptr(void)
{
	return window != NULL;
}

/* state, not a queue: a pointer's past positions are of no use to a
 * reader that has fallen behind -- see platform.h.
 */
int
platform_ptr_read(int *x, int *y, int *buttons)
{
	int moved;

	if (!window)
		return 0;
	lock(&fblock);
	pump_locked();
	if (buthead != buttail) {
		*x = butring[buthead].x;
		*y = butring[buthead].y;
		*buttons = butring[buthead].buttons;
		buthead = (buthead + 1) % BUTRING;
		moved = 1;
	} else {
		moved = ptrmoved;
		if (moved) {
			ptrmoved = 0;
			*x = ptrx;
			*y = ptry;
			*buttons = ptrbuttons;
		}
	}
	unlock(&fblock);
	return moved;
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

/* one mode, which is the window this was started with. A host window
 * can be any size, so the list is what we have rather than what the
 * hardware offers.
 */
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

	checkrect(L, x, y, w, h);	/* raises, so before the lock */
	px[0] = (unsigned char)(color & 0xff);		/* blue */
	px[1] = (unsigned char)((color >> 8) & 0xff);	/* green */
	px[2] = (unsigned char)((color >> 16) & 0xff);	/* red */
	px[3] = 0;

	lock(&fblock);
	for (lua_Integer row = 0; row < h; row++) {
		unsigned char *p = shadow + ((y + row) * fbw + x) * 4;

		for (lua_Integer col = 0; col < w; col++, p += 4)
			memcpy(p, px, 4);
	}
	dirty = 1;
	unlock(&fblock);

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
	lock(&fblock);
	for (lua_Integer row = 0; row < h; row++)
		memcpy(shadow + ((y + row) * fbw + x) * 4,
		    pixels + row * w * 4, (size_t)w * 4);
	dirty = 1;
	unlock(&fblock);

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

	/* the buffer before the lock: luaL_buffinitsize can raise, and a
	 * lua error out of here would leave the lock held.
	 */
	char *out = luaL_buffinitsize(L, &b, (size_t)w * h * bpp);

	lock(&fblock);
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
	unlock(&fblock);

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

	lock(&fblock);
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
	dirty = 1;
	unlock(&fblock);

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

#else	/* no SDL: the machine has no display, and says so */

int
fb_open(int w, int h)
{
	(void)w;
	(void)h;
	kernel_say("fb: this binary was built without SDL");
	return -1;
}

void
fb_pump(void)
{
}

void
fb_flush(void)
{
}

int
platform_have_fb(void)
{
	return 0;
}

int
platform_have_kbd(void)
{
	return 0;
}

int
platform_kbd_read(void)
{
	return -1;
}

int
platform_have_ptr(void)
{
	return 0;
}

int
platform_ptr_read(int *x, int *y, int *buttons)
{
	(void)x;
	(void)y;
	(void)buttons;
	return 0;
}

static const luaL_Reg fblib[] = { { NULL, NULL } };

int luaopen_los_platform_fb(lua_State *L);

int
luaopen_los_platform_fb(lua_State *L)
{
	luaL_newlib(L, fblib);
	return 1;
}

#endif
