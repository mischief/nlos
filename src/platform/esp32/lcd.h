/* luaos_ prefix, not esp_lcd_: that is ESP-IDF's own namespace and
 * this file calls into it. The console_write collision was the lesson.
 */
/* the Cardputer's ST7789 panel, as the framebuffer task/fb.lua serves.
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
int luaos_lcd_width(void);
int luaos_lcd_height(void);

/* rect ops. colour is 0xRRGGBB; `pix` is w*h*4 bytes of BGRx, the
 * layout efi's Blt uses and so the one fb.lua's clients already speak.
 * 0 on success.
 */
int luaos_lcd_fill(int x, int y, int w, int h, uint32_t rgb);
int luaos_lcd_load(int x, int y, int w, int h, const unsigned char *pix);

#endif
