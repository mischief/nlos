/* luaos_ prefix, not esp_lcd_: that is ESP-IDF's own namespace and
 * this file calls into it. The console_write collision was the lesson.
 */
/* the ST7789 panel, as the framebuffer task/fb.lua serves.
 *
 * No font here, deliberately. fb.lua "knows rectangles, pixels and a
 * fill colour; it does not know what a window is, what a font is, or
 * who is drawing" -- so glyphs are rendered above this, in lua, and
 * arrive as an ordinary pixel rectangle. The board drivers this was
 * ported from put text rendering in C because they have no lua layer
 * to put it in.
 */
#ifndef ESP32_LCD_H
#define ESP32_LCD_H

#include <stdint.h>

int luaos_lcd_present(void);		/* probe once; brings up the panel */
/* unload needs a copy: this panel has no SDO wired, so nothing can be
 * read back off it. Costs 64800 bytes of internal SRAM while on.
 */
int luaos_lcd_shadow(int on);
int luaos_lcd_unload(int x, int y, int w, int h, unsigned char *out);

/* the same rectangle as RGB, three bytes and no pad, for a caller
 * writing a file rather than drawing: the channels are already eight
 * bits wide inside unload, and taking the pad out again in lua costs
 * more than the transfer that follows it.
 */
int luaos_lcd_unload_rgb(int x, int y, int w, int h, unsigned char *out);

/* the same rectangle as packed 1bpp, MSB first -- the shadow's own
 * layout, so nothing expands it to BGRx and packs it again.
 */
int luaos_lcd_unload1(int x, int y, int w, int h, unsigned char *out);
int luaos_lcd_width(void);
int luaos_lcd_height(void);

/* rect ops. colour is 0xRRGGBB; `pix` is w*h*4 bytes of BGRx, the
 * layout efi's Blt uses and so the one fb.lua's clients already speak.
 * 0 on success.
 */
int luaos_lcd_fill(int x, int y, int w, int h, uint32_t rgb);
int luaos_lcd_load(int x, int y, int w, int h, const unsigned char *pix);
int luaos_lcd_load16(int x, int y, int w, int h, const unsigned char *pix);
/* move a full-width band from (0,y) to (0,toy); -1 if it cannot, and
 * the caller redraws. Needs the color copy, so PSRAM. */
int luaos_lcd_scroll(int x, int y, int tox, int toy, int w, int h);

/* Move, show or hide the cursor. A negative x or y leaves that
 * coordinate alone and a negative `on` leaves the visibility alone, so
 * a move is cursor(x, y, -1) and a hide is cursor(-1, -1, 0).
 *
 * -1 where the machine cannot have one: the cursor is composited over
 * the colour shadow and repaired from it, so a board without one has no
 * way to know what a cursor covered.
 */
int luaos_lcd_cursor(int x, int y, int on);

/* queue NBAND transfers plus `extra`, wait `settle` ms, then drain.
 * Answers how many completions the semaphore refused.
 */
int luaos_lcd_spiprobe(int extra, int settle);

#endif
