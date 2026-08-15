/* the ST7789 panel, over IDF's esp_lcd: one driver, a pin map and a
 * geometry per board. Pin maps and offsets are from clm's esp32
 * firmware (board_config.h), the tested source for these boards.
 * A panel smaller than the ST7789's 240x320 RAM is a window inside it,
 * and wrong offsets draw a shifted, wrapped picture rather than fail.
 */

#include <sdkconfig.h>

/* Outside the board guard: the stubs at the bottom answer the same
 * declarations, so a board with no panel needs the header and the fixed
 * width types as much as one with a panel does.
 */
#include <stdint.h>

#include "lcd.h"

#if CONFIG_LUAOS_BOARD_CARDPUTER || CONFIG_LUAOS_BOARD_TDECK

#include <string.h>

#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
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
/* Above the vendor's 27MHz and clm's 40MHz, below the ST7789's ~62MHz
 * write ceiling. The shared bus is short here, and a faster pixel clock
 * is what makes a scroll's full-frame move quick. The SD sets its own
 * clock, so this does not touch it.
 */
#define LCD_PCLK_HZ	(60 * 1000 * 1000)
#define LCD_GAP_X	0
#define LCD_GAP_Y	0

/* the card and the radio share this bus, so tdeck.c owns it. */
#define LCD_BUS_SHARED	1

#endif

/* Staging bands of RGB565, in DMA-capable internal memory. Callers'
 * pixels are on the shared heap, which is not DMA-capable, so a copy is
 * needed whatever the size; this only sets how many transfers a large
 * rectangle costs.
 */

/* Several, so a caller fills the next while the panel takes the last.
 * Smaller and more beats one large, and internal SRAM is the scarce
 * pool here, so what matters is the product.
 */
#define BAND_ROWS	8
#define NBAND		3
#define BANDPX		(LCD_W * BAND_ROWS)

static esp_lcd_panel_handle_t panel;
static uint16_t *bands[NBAND];
static int bandi;

/* An optional copy of what was written, for unload(). The panel cannot
 * be read -- the ST7789's SDO is routed nowhere -- so a copy we kept is
 * the only honest answer.
 */

/* One bit a pixel: a screenshot shows shape, not colour, and ink is any
 * pixel that is not black. RGB565 would be 64800 bytes and kills a
 * board with no PSRAM, where 4050 is affordable.
 */
#define SHADOW_BYTES ((LCD_W * LCD_H + 7) / 8)
static unsigned char *shadow;

/* A full-color copy of the glass, in wire-order RGB565, for scrolling.
 *
 * The panel cannot be read and cannot scroll in hardware in this
 * orientation, so moving a line up means having the pixels to move. This
 * holds them: a scroll is a memmove here and one DMA of the moved band,
 * where a redraw renders every cell again. At 150KB it lives in PSRAM
 * and exists only where there is PSRAM -- the Cardputer redraws instead.
 */
static uint16_t *cshadow;
static int probed, present;

/* Raised when a transfer has finished. draw_bitmap queues and returns,
 * so the pixels belong to the DMA until this fires -- and `band` is one
 * buffer every caller reuses.
 */
static SemaphoreHandle_t sent;

static bool
transdone(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *ed,
    void *arg)
{
	BaseType_t woke = pdFALSE;

	(void)io;
	(void)ed;
	(void)arg;
	if (sent != NULL)
		xSemaphoreGiveFromISR(sent, &woke);
	return woke == pdTRUE;
}

/* Queued and not yet reported done. A transfer that finished before we
 * came round again is a take that does not block, which is the point:
 * blocking costs a scheduler tick, many times a transfer.
 */
static int inflight;

/* wait for every outstanding transfer. Needed before a buffer that is
 * not one of ours is handed to the DMA, and before reading the panel.
 */
static void
drain(void)
{
	while (inflight > 0) {
		xSemaphoreTake(sent, portMAX_DELAY);
		inflight--;
	}
}

/* the next staging buffer to fill. Blocks only when every one of them
 * is still with the DMA.
 */
static uint16_t *
bandnext(void)
{
	uint16_t *b;

	/* the queue is served in order and these are handed out in
	 * order, so the one coming round again is the oldest: fewer
	 * outstanding than there are buffers means it has been sent.
	 */
	while (inflight >= NBAND) {
		xSemaphoreTake(sent, portMAX_DELAY);
		inflight--;
	}
	b = bands[bandi];
	bandi = (bandi + 1) % NBAND;
	return b;
}

/* queue one rectangle from a staging buffer and return. The pixels
 * belong to the DMA until a completion is counted, which bandnext does
 * before handing that buffer out again.
 */
static int
sendband(int x, int y, int w, int h, const uint16_t *px)
{
	if (esp_lcd_panel_draw_bitmap(panel, x, y, x + w, y + h,
	    (void *)px) != ESP_OK)
		return -1;
	inflight++;
	return 0;
}

/* one rectangle from anywhere, and not back until the panel has it.
 * For a caller whose pixels this cannot keep -- a stack buffer, or the
 * shadow, which the next write would change underneath the DMA.
 */
static int
sendrect(int x, int y, int w, int h, const uint16_t *px)
{
	if (sendband(x, y, w, h, px) != 0)
		return -1;
	drain();
	return 0;
}

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
	/* one transfer outstanding, because there is one band buffer.
	 * draw_bitmap queues and returns, so the caller must not touch
	 * the pixels again until on_color_trans_done says they are gone.
	 */
	esp_lcd_panel_io_spi_config_t io_cfg = {
		.dc_gpio_num = LCD_DC,
		.cs_gpio_num = LCD_CS,
		.pclk_hz = LCD_PCLK_HZ,
		.lcd_cmd_bits = 8,
		.lcd_param_bits = 8,
		.spi_mode = 0,
		.trans_queue_depth = NBAND,
		.on_color_trans_done = transdone,
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

	for (int i = 0; i < NBAND; i++) {
		bands[i] = heap_caps_malloc(BANDPX * sizeof *bands[i],
		    MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
		if (bands[i] == NULL)
			return 0;
	}
	/* counting, not binary: with several in flight the completions
	 * arrive before anyone waits, and a binary one would lose all
	 * but the last.
	 */
	sent = xSemaphoreCreateCounting(NBAND, 0);
	if (sent == NULL)
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

			uint16_t *b = bandnext();

			memset(b, 0, (size_t)LCD_W * n * sizeof *b);
			sendband(0, y, LCD_W, n, b);
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
	if (on && shadow == NULL && cshadow == NULL) {
		/* Where there is PSRAM, keep a full-color copy and nothing
		 * else: it is the exact pixels the panel gets, so a
		 * screenshot is true color and a scroll has the pixels to
		 * move. Without PSRAM a color frame does not fit, so the
		 * fallback is one bit per pixel -- shape, not color -- in
		 * internal memory.
		 */
#if CONFIG_SPIRAM
		cshadow = heap_caps_malloc((size_t)LCD_W * LCD_H *
		    sizeof *cshadow, MALLOC_CAP_SPIRAM);
		if (cshadow != NULL) {
			memset(cshadow, 0, (size_t)LCD_W * LCD_H *
			    sizeof *cshadow);
			return 0;
		}
#endif
		shadow = heap_caps_malloc(SHADOW_BYTES,
		    MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
		if (shadow == NULL)
			return -1;
		memset(shadow, 0, SHADOW_BYTES);
	} else if (!on) {
		if (shadow != NULL) {
			heap_caps_free(shadow);
			shadow = NULL;
		}
		if (cshadow != NULL) {
			heap_caps_free(cshadow);
			cshadow = NULL;
		}
	}
	return 0;
}

/* is this colour ink, for the one-bit copy?
 *
 * Brightness rather than "not black". A program that draws on a dark
 * background rather than a black one -- bin/smiley.lua uses 0x101018 --
 * otherwise marks every pixel it touches, and the screenshot comes back
 * a solid block with the picture invisible inside it.
 *
 * Rec. 601 luma, halved to keep the arithmetic in a byte. The threshold
 * is low: this is asking "did something get drawn here", not matching a
 * palette.
 */
static int
shadow_ink(uint32_t rgb)
{
	uint32_t r = (rgb >> 16) & 0xff;
	uint32_t g = (rgb >> 8) & 0xff;
	uint32_t b = rgb & 0xff;

	return ((r * 77 + g * 151 + b * 28) >> 8) > 0x30;
}

static void
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

	if (!present)
		return -1;
	if (x < 0 || y < 0 || w <= 0 || h <= 0 ||
	    x + w > LCD_W || y + h > LCD_H)
		return -1;

	/* the color copy is the true one -- the exact pixels sent to the
	 * panel -- so where it exists a screenshot shows real colors, not
	 * the one-bit shape. RGB565 is stored wire-order (byte-swapped);
	 * undo that, then widen each channel to eight bits.
	 */
	if (cshadow != NULL) {
		for (row = 0; row < h; row++)
			for (col = 0; col < w; col++) {
				uint16_t cs = cshadow[(size_t)(y + row) *
				    LCD_W + x + col];
				uint16_t v = (uint16_t)((cs >> 8) | (cs << 8));
				unsigned r5 = (v >> 11) & 0x1f;
				unsigned g6 = (v >> 5) & 0x3f;
				unsigned b5 = v & 0x1f;
				unsigned char *px = out +
				    ((size_t)row * w + col) * 4;

				px[0] = (unsigned char)((b5 << 3) | (b5 >> 2));
				px[1] = (unsigned char)((g6 << 2) | (g6 >> 4));
				px[2] = (unsigned char)((r5 << 3) | (r5 >> 2));
				px[3] = 0;
			}
		return 0;
	}

	if (shadow == NULL)
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

	if (!present || (shadow == NULL && cshadow == NULL))
		return -1;
	if (x < 0 || y < 0 || w <= 0 || h <= 0 ||
	    x + w > LCD_W || y + h > LCD_H)
		return -1;

	for (row = 0; row < h; row++) {
		unsigned char byte = 0;
		int nbit = 0;

		for (col = 0; col < w; col++) {
			size_t idx = (size_t)(y + row) * LCD_W + x + col;
			int ink;

			/* one bit derived from the color copy where there is
			 * one -- any non-black pixel is ink -- or read from
			 * the one-bit plane where that is all there is.
			 */
			if (cshadow != NULL)
				ink = cshadow[idx] != 0;
			else
				ink = (shadow[idx >> 3] >> (idx & 7)) & 1;
			byte = (unsigned char)(byte << 1) |
			    (unsigned char)ink;
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

/* the cursor.
 *
 * plan 9's swcursor, minus the backing store. That exists to remember
 * what a cursor covered so it can be put back; cshadow already holds
 * every pixel the machine drew, so the repair reads from there and
 * there is nothing to keep in step.
 *
 * The invariant is one line: cshadow never contains the cursor. What is
 * on the glass is cshadow plus the cursor, and every path that writes
 * pixels writes cshadow first -- so erasing is a copy out of cshadow,
 * and a draw that lands under the cursor only has to put it back on
 * top afterwards.
 *
 * Without cshadow there is no cursor: the panel cannot be read, so
 * nothing could say what was underneath. A board with no PSRAM says no
 * rather than smearing.
 */
#define CURSOR_R	5			/* arms, so 11x11 */
#define CURSOR_SIDE	(2 * CURSOR_R + 1)
#define CURSOR_RGB	0x00ff00		/* green, over dark text */

static int curx = -1, cury = -1, curshown;

/* the cursor's rectangle, clipped to the screen. 0 if none of it is on
 * the glass, which is also what an unplaced cursor gives.
 */
static int
cursor_rect(int *x, int *y, int *w, int *h)
{
	int x0, y0, x1, y1;

	if (curx < 0 || cury < 0 || cshadow == NULL)
		return 0;
	x0 = curx - CURSOR_R;
	y0 = cury - CURSOR_R;
	x1 = curx + CURSOR_R + 1;
	y1 = cury + CURSOR_R + 1;
	if (x0 < 0)
		x0 = 0;
	if (y0 < 0)
		y0 = 0;
	if (x1 > LCD_W)
		x1 = LCD_W;
	if (y1 > LCD_H)
		y1 = LCD_H;
	if (x1 <= x0 || y1 <= y0)
		return 0;
	*x = x0;
	*y = y0;
	*w = x1 - x0;
	*h = y1 - y0;
	return 1;
}

/* paint the cursor's rectangle: the pixels underneath from cshadow,
 * with the crosshair drawn over them when `with` is set. One transfer
 * either way -- 242 bytes for an 11x11, against 10KB for a text band.
 */
static void
cursor_blit(int with)
{
	uint16_t buf[CURSOR_SIDE * CURSOR_SIDE];
	int x, y, w, h, r, c;

	if (!cursor_rect(&x, &y, &w, &h))
		return;

	for (r = 0; r < h; r++)
		for (c = 0; c < w; c++)
			buf[r * w + c] =
			    cshadow[(size_t)(y + r) * LCD_W + x + c];

	if (with) {
		uint16_t ink = rgb565(CURSOR_RGB);

		for (c = 0; c < w; c++)
			buf[(cury - y) * w + c] = ink;
		for (r = 0; r < h; r++)
			buf[r * w + (curx - x)] = ink;
	}
	sendrect(x, y, w, h, buf);
}

/* whether a rectangle just written overlaps the cursor, so the caller
 * knows to put it back. Asked after the write, since cshadow is already
 * current by then and the repair is just a paint.
 */
static int
cursor_hit(int x, int y, int w, int h)
{
	int cx, cy, cw, ch;

	if (!curshown || !cursor_rect(&cx, &cy, &cw, &ch))
		return 0;
	return !(x >= cx + cw || x + w <= cx || y >= cy + ch || y + h <= cy);
}

/* move the cursor, show it, or hide it.
 *
 * on < 0 leaves the visibility alone, which is what a move is.
 */
int
luaos_lcd_cursor(int x, int y, int on)
{
	if (!present || cshadow == NULL)
		return -1;

	if (curshown)
		cursor_blit(0);		/* erase from where it was */

	if (x >= 0)
		curx = x;
	if (y >= 0)
		cury = y;
	if (on >= 0)
		curshown = on != 0;

	if (curshown)
		cursor_blit(1);
	return 0;
}

int
luaos_lcd_fill(int x, int y, int w, int h, uint32_t rgb)
{
	uint16_t px = rgb565(rgb);
	int i, row;

	if (!present || w <= 0 || h <= 0 || w > LCD_W)
		return -1;

	if (shadow != NULL) {
		int r, c, ink = shadow_ink(rgb);

		for (r = 0; r < h; r++)
			for (c = 0; c < w; c++)
				shadow_set(x + c, y + r, ink);
	}
	if (cshadow != NULL) {
		int r, c;

		for (r = 0; r < h; r++)
			for (c = 0; c < w; c++)
				cshadow[(size_t)(y + r) * LCD_W + x + c] = px;
	}

	/* a buffer of its own per band, though they all hold the same
	 * pixels: one sent twice would be written again while the DMA
	 * still had it.
	 */
	for (row = 0; row < h; row += BAND_ROWS) {
		int n = (h - row < BAND_ROWS) ? h - row : BAND_ROWS;
		uint16_t *b = bandnext();

		for (i = 0; i < w * n; i++)
			b[i] = px;
		if (sendband(x, y + row, w, n, b) != 0)
			return -1;
	}
	if (cursor_hit(x, y, w, h))
		cursor_blit(1);
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
		uint16_t *band = bandnext();

		for (i = 0; i < count; i++) {
			uint32_t b = src[i * 4 + 0];
			uint32_t g = src[i * 4 + 1];
			uint32_t r = src[i * 4 + 2];

			band[i] = rgb565((r << 16) | (g << 8) | b);
			if (shadow != NULL)
				shadow_set(x + i % w, y + row + i / w,
				    shadow_ink((r << 16) | (g << 8) | b));
			if (cshadow != NULL)
				cshadow[(size_t)(y + row + i / w) * LCD_W +
				    x + i % w] = band[i];
		}
		if (sendband(x, y + row, w, n, band) != 0)
			return -1;
	}
	if (cursor_hit(x, y, w, h))
		cursor_blit(1);
	return 0;
}

/* The same, in the panel's own format and wire byte order, so this
 * copies where the four-byte path walks pixels. The band is copied at
 * all only because it must be DMA-capable and the caller's is not.
 */
int
luaos_lcd_load16(int x, int y, int w, int h, const unsigned char *pix)
{
	int row;

	if (!present || w <= 0 || h <= 0 || w > LCD_W)
		return -1;

	for (row = 0; row < h; row += BAND_ROWS) {
		int n = (h - row < BAND_ROWS) ? h - row : BAND_ROWS;
		const unsigned char *src = pix + (size_t)row * w * 2;
		uint16_t *band = bandnext();
		int i;

		memcpy(band, src, (size_t)w * n * 2);
		if (cshadow != NULL)
			for (i = 0; i < n; i++)
				memcpy(&cshadow[(size_t)(y + row + i) *
				    LCD_W + x], src + (size_t)i * w * 2,
				    (size_t)w * 2);
		/* the one-bit copy has no format to share: a board without
		 * PSRAM keeps shape, so this still asks per pixel.
		 */
		if (shadow != NULL)
			for (i = 0; i < w * n; i++)
				shadow_set(x + i % w, y + row + i / w,
				    (src[i * 2] | src[i * 2 + 1]) != 0);
		if (sendband(x, y + row, w, n, band) != 0)
			return -1;
	}
	if (cursor_hit(x, y, w, h))
		cursor_blit(1);
	return 0;
}

/* Move a full-width band of the glass up or down, using the color copy.
 *
 * The only move a console makes: x and tox zero, the whole width, h rows
 * from y to toy. The pixels come from cshadow, so no readback is needed
 * and no cell is rendered again -- a memmove and one DMA of the band
 * that moved, against a redraw of every row. Anything else, or no color
 * copy, returns -1 and the caller redraws.
 */
int
luaos_lcd_scroll(int x, int y, int tox, int toy, int w, int h)
{
	int row;

	(void)w;
	if (!present || cshadow == NULL)
		return -1;
	if (x != 0 || tox != 0 || h <= 0)
		return -1;
	if (y < 0 || toy < 0 || y + h > LCD_H || toy + h > LCD_H)
		return -1;

	memmove(cshadow + (size_t)toy * LCD_W, cshadow + (size_t)y * LCD_W,
	    (size_t)h * LCD_W * sizeof *cshadow);
	if (shadow != NULL) {
		size_t bpr = LCD_W / 8;

		memmove(shadow + (size_t)toy * bpr, shadow + (size_t)y * bpr,
		    (size_t)h * bpr);
	}
	/* DMA straight from the shadow rather than staging through band:
	 * the rows are already there and already in the panel's format.
	 */
	for (row = 0; row < h; row += BAND_ROWS) {
		int n = (h - row < BAND_ROWS) ? h - row : BAND_ROWS;

		if (sendrect(0, toy + row, LCD_W, n,
		    cshadow + (size_t)(toy + row) * LCD_W) != 0)
			return -1;
	}
	if (cursor_hit(0, toy, LCD_W, h))
		cursor_blit(1);
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

int
luaos_lcd_scroll(int x, int y, int tox, int toy, int w, int h)
{
	(void)x; (void)y; (void)tox; (void)toy; (void)w; (void)h;
	return -1;
}

int
luaos_lcd_cursor(int x, int y, int on)
{
	(void)x; (void)y; (void)on;
	return -1;
}

#endif
