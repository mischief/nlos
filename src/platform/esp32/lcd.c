/* the Cardputer's ST7789, over IDF's esp_lcd.
 *
 * Pin map, orientation and the panel offsets are from
 * clm's esp32 firmware (board_config.h), which is the tested
 * source for this board. The offsets are the part not to rederive: a
 * 240x135 panel sits inside the ST7789's 240x320 RAM, and in this
 * landscape orientation (swap_xy + mirror_x) that lands at
 * colstart=40, rowstart=240-(135+52)=53. Wrong offsets do not fail --
 * they draw a shifted, wrapped picture, which reads as a broken driver.
 *
 * No shadow framebuffer, which is the memory decision here. 240x135 at
 * RGB565 is 64800 bytes against ~190KB free on a board with no PSRAM,
 * and the fb protocol is rectangle-based: fill and load go straight at
 * the panel. Only unload -- reading pixels back -- would need one, and
 * ST7789 readback over SPI is unreliable anyway, so it says so instead
 * of guessing.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_CARDPUTER || CONFIG_LUAOS_BOARD_TDECK

#include <string.h>

#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <esp_heap_caps.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_vendor.h>

#include "platform.h"
#include "esp32.h"
#include "lcd.h"

#if CONFIG_LUAOS_BOARD_CARDPUTER

#define LCD_HOST	SPI3_HOST
#define LCD_W		240
#define LCD_H		135
#define LCD_SCK		36
#define LCD_MOSI	35
#define LCD_CS		37
#define LCD_DC		34
#define LCD_RST		33
#define LCD_BL		38
#define LCD_PCLK_HZ	(40 * 1000 * 1000)
#define LCD_GAP_X	40
#define LCD_GAP_Y	53

/* the Cardputer owns its bus: nothing else is on SPI3. */
#define LCD_BUS_SHARED	0

#else /* CONFIG_LUAOS_BOARD_TDECK */

/* A whole 320x240 panel, and no gap: the Cardputer's 240x135 is a
 * window onto a larger controller, which is what its offsets correct
 * for. This one uses the full frame, so the same driver needs none.
 */
#define LCD_HOST	TDECK_SPI_HOST
#define LCD_W		320
#define LCD_H		240
#define LCD_SCK		TDECK_SPI_SCK
#define LCD_MOSI	TDECK_SPI_MOSI
#define LCD_CS		TDECK_TFT_CS
#define LCD_DC		TDECK_TFT_DC

/* no reset line of its own: the panel is tied to the board reset, and
 * esp_lcd takes -1 to mean exactly that.
 */
#define LCD_RST		(-1)
#define LCD_BL		TDECK_TFT_BL
#define LCD_PCLK_HZ	(40 * 1000 * 1000)
#define LCD_GAP_X	0
#define LCD_GAP_Y	0

/* the card and the radio share this bus, so tdeck.c owns it. */
#define LCD_BUS_SHARED	1

#endif

/* One transfer's worth of RGB565, in DMA-capable internal memory.
 *
 * Sized to a comfortable band rather than the screen: a term redrawing
 * one line of text moves 240x12, and anything larger is chunked by rows
 * below. Callers' pixels come from lua strings on the shared heap,
 * which is not DMA-capable, so a staging buffer is needed regardless of
 * size -- this only decides how many transfers a big rectangle costs.
 */
#define BAND_ROWS	16
#define BANDPX		(LCD_W * BAND_ROWS)

static esp_lcd_panel_handle_t panel;
static uint16_t *band;

/* An optional copy of what was written, for unload().
 *
 * The panel cannot be read: the Cardputer schematic's LCD connector is
 * eight pins -- RST, RS, MOSI, SCK, CS, BL, 3V3, GND -- and the
 * ST7789's SDO is routed nowhere. So readback is impossible rather than
 * merely unreliable, and the only honest unload is a copy we kept.
 *
 * ONE BIT per pixel, and that is a real limit worth stating: a
 * screenshot shows shape, not colour. Ink is any pixel that is not
 * black.
 *
 * It is one bit because full RGB565 measured 64800 bytes and killed the
 * machine -- "proc 0 (cons) died: not enough memory" on a board with no
 * PSRAM, where cons alone wants ~60KB for lib/thread.lua. At 4050 bytes
 * this is affordable, and what it is for -- checking that glyphs landed
 * where they should -- needs shape rather than hue.
 */
#define SHADOW_BYTES ((LCD_W * LCD_H + 7) / 8)
static unsigned char *shadow;
static int probed, present;

/* ST7789 wants big-endian RGB565 on the wire. Doing the swap here means
 * the rest of this file can think in ordinary host-order pixels.
 */
static inline uint16_t
rgb565(uint32_t rgb)
{
	uint16_t v = (uint16_t)(((rgb >> 8) & 0xf800) |
	    ((rgb >> 5) & 0x07e0) | ((rgb >> 3) & 0x001f));

	return (uint16_t)((v >> 8) | (v << 8));
}

int
luaos_lcd_present(void)
{
	spi_bus_config_t bus = {
		.mosi_io_num = LCD_MOSI,
		.miso_io_num = -1,
		.sclk_io_num = LCD_SCK,
		.quadwp_io_num = -1,
		.quadhd_io_num = -1,
		.max_transfer_sz = BANDPX * (int)sizeof(uint16_t),
	};
	esp_lcd_panel_io_spi_config_t io_cfg = {
		.dc_gpio_num = LCD_DC,
		.cs_gpio_num = LCD_CS,
		.pclk_hz = LCD_PCLK_HZ,
		.lcd_cmd_bits = 8,
		.lcd_param_bits = 8,
		.spi_mode = 0,
		.trans_queue_depth = 10,
	};
	esp_lcd_panel_dev_config_t dev_cfg = {
		.reset_gpio_num = LCD_RST,
		/* RGB on both boards. The T-Deck's TFT_eSPI setup says
		 * TFT_BGR, but clm drives this panel through esp_lcd with
		 * RGB and works -- the two libraries do not mean the same
		 * thing by the flag, and the working code wins.
		 */
		.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
		.bits_per_pixel = 16,
	};
	gpio_config_t bl = {
		.pin_bit_mask = 1ULL << LCD_BL,
		.mode = GPIO_MODE_OUTPUT,
	};
	esp_lcd_panel_io_handle_t io = NULL;

	if (probed)
		return present;
	probed = 1;

	/* on a board where the bus is ours, set it up; where it is
	 * shared, tdeck.c has done it (or will have, for whichever
	 * driver probes first) and initialising it twice fails.
	 */
#if LCD_BUS_SHARED
	(void)bus;
	if (esp_tdeck_spi_init() != 0)
		return 0;
#else
	if (spi_bus_initialize(LCD_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK)
		return 0;
#endif
	if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST,
	    &io_cfg, &io) != ESP_OK)
		return 0;
	if (esp_lcd_new_panel_st7789(io, &dev_cfg, &panel) != ESP_OK)
		return 0;

	esp_lcd_panel_reset(panel);
	esp_lcd_panel_init(panel);
	/* inverted, and landscape: this panel is wired with its colours
	 * inverted and its axes swapped, so a driver that skips these
	 * shows a mirrored negative rather than nothing.
	 */
	esp_lcd_panel_invert_color(panel, true);
	/* native portrait to landscape. Both boards want the same
	 * transform; only the gap differs, because the Cardputer's panel
	 * is a window onto the same 240x320 controller.
	 */
	esp_lcd_panel_swap_xy(panel, true);
	esp_lcd_panel_mirror(panel, true, false);
	esp_lcd_panel_set_gap(panel, LCD_GAP_X, LCD_GAP_Y);
	esp_lcd_panel_disp_on_off(panel, true);

	band = heap_caps_malloc(BANDPX * sizeof *band,
	    MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
	if (band == NULL)
		return 0;

	/* and blank it before the backlight comes on. The controller's
	 * RAM holds whatever was there at power-on -- the last image of a
	 * previous firmware, or noise -- and lighting that is indis-
	 * tinguishable from a crash. Costs one full-screen fill at boot.
	 */
	{
		int y;

		for (y = 0; y < LCD_H; y += BAND_ROWS) {
			int n = (LCD_H - y < BAND_ROWS) ? LCD_H - y :
			    BAND_ROWS;

			memset(band, 0, (size_t)LCD_W * n * sizeof *band);
			esp_lcd_panel_draw_bitmap(panel, 0, y, LCD_W, y + n,
			    band);
		}
	}

	/* backlight last: a panel lit before it is initialised shows
	 * whatever was in RAM at power-on, which looks like a crash.
	 */
	gpio_config(&bl);
	gpio_set_level(LCD_BL, 1);

	present = 1;

#if CONFIG_LUAOS_FB_SHADOW
	/* a development build: keep what is written so unload works.
	 * Failing here is not fatal -- the panel is still usable, only
	 * unload is not.
	 */
	luaos_lcd_shadow(1);
#endif
	return 1;
}

int
luaos_lcd_shadow(int on)
{
	if (!present && on)
		return -1;
	if (on && shadow == NULL) {
		/* PSRAM by preference: nothing here is touched by DMA and
		 * nothing reads it on a hot path -- it is written on a draw
		 * and read only when a screenshot asks -- so it has no
		 * claim on internal sram. On the T-Deck that is 9600 bytes
		 * of the scarce pool handed back; where there is no PSRAM
		 * the fallback is the only option and the buffer is small.
		 */
#if CONFIG_SPIRAM
		shadow = heap_caps_malloc(SHADOW_BYTES,
		    MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#endif
		if (shadow == NULL)
			shadow = heap_caps_malloc(SHADOW_BYTES,
			    MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
		if (shadow == NULL)
			return -1;
		memset(shadow, 0, SHADOW_BYTES);
	} else if (!on && shadow != NULL) {
		heap_caps_free(shadow);
		shadow = NULL;
	}
	return 0;
}

static inline void
shadow_set(int x, int y, int ink)
{
	size_t bit = (size_t)y * LCD_W + x;

	if (ink)
		shadow[bit >> 3] |= (unsigned char)(1u << (bit & 7));
	else
		shadow[bit >> 3] &= (unsigned char)~(1u << (bit & 7));
}

/* white for ink, black for paper, as BGRx -- the layout load() takes.
 * Not the colours that were drawn: see the shadow's comment.
 */
int
luaos_lcd_unload(int x, int y, int w, int h, unsigned char *out)
{
	int row, col;

	if (!present || shadow == NULL)
		return -1;
	if (x < 0 || y < 0 || w <= 0 || h <= 0 ||
	    x + w > LCD_W || y + h > LCD_H)
		return -1;

	for (row = 0; row < h; row++)
		for (col = 0; col < w; col++) {
			size_t bit = (size_t)(y + row) * LCD_W + x + col;
			int ink = (shadow[bit >> 3] >> (bit & 7)) & 1;
			unsigned char *px = out + ((size_t)row * w + col) * 4;
			unsigned char v = ink ? 0xff : 0x00;

			px[0] = v;
			px[1] = v;
			px[2] = v;
			px[3] = 0;
		}
	return 0;
}

/* the shadow's own representation, handed over as-is.
 *
 * unload() expands one bit to four bytes because that is the shared fb
 * protocol's layout, and a caller that wants bits back then packs them
 * again in lua: 960 bytes of garbage per row to produce 30. For a
 * screen that is 130KB of churn on a machine with 61KB free, which is
 * what stopped a screenshot fitting alongside zmodem. This skips both
 * conversions.
 *
 * MSB first, which is PBM's bit order. Returns bytes written, or -1.
 */
int
luaos_lcd_unload1(int x, int y, int w, int h, unsigned char *out)
{
	int row, col, n = 0;

	if (!present || shadow == NULL)
		return -1;
	if (x < 0 || y < 0 || w <= 0 || h <= 0 ||
	    x + w > LCD_W || y + h > LCD_H)
		return -1;

	for (row = 0; row < h; row++) {
		unsigned char byte = 0;
		int nbit = 0;

		for (col = 0; col < w; col++) {
			size_t bit = (size_t)(y + row) * LCD_W + x + col;

			byte = (unsigned char)(byte << 1) |
			    (unsigned char)((shadow[bit >> 3] >> (bit & 7)) & 1);
			if (++nbit == 8) {
				out[n++] = byte;
				byte = 0;
				nbit = 0;
			}
		}
		if (nbit > 0)			/* pad the row to a byte */
			out[n++] = (unsigned char)(byte << (8 - nbit));
	}
	return n;
}

int
luaos_lcd_width(void)
{
	return LCD_W;
}

int
luaos_lcd_height(void)
{
	return LCD_H;
}

int
luaos_lcd_fill(int x, int y, int w, int h, uint32_t rgb)
{
	uint16_t px = rgb565(rgb);
	int i, row;

	if (!present || w <= 0 || h <= 0 || w > LCD_W)
		return -1;

	for (i = 0; i < w * BAND_ROWS; i++)
		band[i] = px;

	if (shadow != NULL) {
		int r, c, ink = (rgb & 0xffffffu) != 0;

		for (r = 0; r < h; r++)
			for (c = 0; c < w; c++)
				shadow_set(x + c, y + r, ink);
	}

	for (row = 0; row < h; row += BAND_ROWS) {
		int n = (h - row < BAND_ROWS) ? h - row : BAND_ROWS;
		if (esp_lcd_panel_draw_bitmap(panel, x, y + row, x + w,
		    y + row + n, band) != ESP_OK)
			return -1;
	}
	return 0;
}

/* BGRx in, RGB565 out. The 4-byte layout is what efi's Blt uses and so
 * what fb.lua's clients already produce; converting here keeps every
 * caller platform-blind.
 */
int
luaos_lcd_load(int x, int y, int w, int h, const unsigned char *pix)
{
	int row;

	if (!present || w <= 0 || h <= 0 || w > LCD_W)
		return -1;

	for (row = 0; row < h; row += BAND_ROWS) {
		int n = (h - row < BAND_ROWS) ? h - row : BAND_ROWS;
		int i, count = w * n;
		const unsigned char *src = pix + (size_t)row * w * 4;

		for (i = 0; i < count; i++) {
			uint32_t b = src[i * 4 + 0];
			uint32_t g = src[i * 4 + 1];
			uint32_t r = src[i * 4 + 2];

			band[i] = rgb565((r << 16) | (g << 8) | b);
			if (shadow != NULL)
				shadow_set(x + i % w, y + row + i / w,
				    (r | g | b) != 0);
		}
		if (esp_lcd_panel_draw_bitmap(panel, x, y + row, x + w,
		    y + row + n, band) != ESP_OK)
			return -1;
	}
	return 0;
}

#else /* !CONFIG_LUAOS_BOARD_CARDPUTER */

int
luaos_lcd_present(void)
{
	return 0;
}

int
luaos_lcd_shadow(int on)
{
	(void)on;
	return -1;
}

int
luaos_lcd_unload(int x, int y, int w, int h, unsigned char *out)
{
	(void)x; (void)y; (void)w; (void)h; (void)out;
	return -1;
}

int
luaos_lcd_unload1(int x, int y, int w, int h, unsigned char *out)
{
	(void)x; (void)y; (void)w; (void)h; (void)out;
	return -1;
}

int
luaos_lcd_width(void)
{
	return 0;
}

int
luaos_lcd_height(void)
{
	return 0;
}

int
luaos_lcd_fill(int x, int y, int w, int h, uint32_t rgb)
{
	(void)x; (void)y; (void)w; (void)h; (void)rgb;
	return -1;
}

int
luaos_lcd_load(int x, int y, int w, int h, const unsigned char *pix)
{
	(void)x; (void)y; (void)w; (void)h; (void)pix;
	return -1;
}

#endif
