/* the Cardputer's ST7789, over IDF's esp_lcd.
 *
 * Pin map, orientation and the panel offsets are from
 * ~/code/c/clm/esp32/firmware/board_config.h, which is the tested
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

#if CONFIG_LUAOS_BOARD_CARDPUTER

#include <string.h>

#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <esp_heap_caps.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_vendor.h>

#include "lcd.h"

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

	if (spi_bus_initialize(LCD_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK)
		return 0;
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
	esp_lcd_panel_swap_xy(panel, true);
	esp_lcd_panel_mirror(panel, true, false);
	esp_lcd_panel_set_gap(panel, LCD_GAP_X, LCD_GAP_Y);
	esp_lcd_panel_disp_on_off(panel, true);

	band = heap_caps_malloc(BANDPX * sizeof *band,
	    MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
	if (band == NULL)
		return 0;

	/* backlight last: a panel lit before it is initialised shows
	 * whatever was in RAM at power-on, which looks like a crash.
	 */
	gpio_config(&bl);
	gpio_set_level(LCD_BL, 1);

	present = 1;
	return 1;
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
