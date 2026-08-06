/* the T-Deck's touch panel: a GT911 at 0x5d on the shared i2c bus.
 *
 * State, not a stream. A pointer has a current position and a current
 * button, and a reader that falls behind wants where the finger is now
 * rather than every place it has been -- so this keeps one position and
 * a changed flag, and nothing queues. That is the same bargain plan 9's
 * mouse file makes, and it is why a slow client lags in resolution
 * rather than in time.
 *
 * Polled from the idle path beside the keyboard rather than driven off
 * TDECK_TOUCH_INT, for the reason kbd.c gives: the read is i2c and an
 * isr cannot do one, so the interrupt could only set a flag for this
 * poll to notice. The pin is defined and stays unused; it is what a
 * board that sleeps between touches would need.
 *
 * Register map: a 16-bit big-endian register address, 0x814e holding
 * the buffer status (bit 7) and the number of points (low nibble), and
 * the first point at 0x8150 as x, y and size, each a little-endian
 * pair. The track id is at 0x814f, below the coordinates rather than
 * in front of them -- reading it as the first byte of the point shifts
 * every field by one and produces coordinates in the tens of
 * thousands, which is what a byte in the high half looks like.
 *
 * The status must be written back as zero or the controller never
 * reports another frame.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/i2c_master.h>
#include <esp_timer.h>
#include <stdint.h>

#include "esp32.h"
#include "lcd.h"
#include "touch.h"

#define GT911_PRODUCT_ID	0x8140
#define GT911_XMAX		0x8048	/* config: resolution, little-endian */
#define GT911_YMAX		0x804a
#define GT911_STATUS		0x814e
#define GT911_POINT1		0x8150

/* 10ms. A finger crossing the panel takes a good fraction of a second,
 * so this is far finer than a hand can steer, and it is one 8-byte
 * read on a bus the keyboard is already using at 8ms.
 */
#define TOUCH_POLL_US		10000

static i2c_master_dev_handle_t tp;
static int probed, present;
static int curx, cury, curdown;

/* the panel's own resolution, from its config registers. It is mounted
 * in portrait under a display driven landscape, so this is 240x320
 * against the screen's 320x240 -- read rather than assumed, since the
 * numbers that would be wrong are exactly the ones nothing else checks.
 */
static int panw = 240, panh = 320;

/* panel coordinates to screen coordinates.
 *
 * lcd.c drives this glass with swap_xy and mirror_x, and the touch
 * controller reports in the glass's own frame, so the same two
 * operations undo it: the axes trade places and one of them counts
 * backwards. Established by tapping the screen's top left corner, which
 * reads as panel (218, 16) -- y near zero and x near its maximum.
 */
static void
to_screen(int px, int py, int *sx, int *sy)
{
	int w = luaos_lcd_width(), h = luaos_lcd_height();

	if (w <= 0 || h <= 0 || panw <= 0 || panh <= 0) {
		*sx = px;
		*sy = py;
		return;
	}
	*sx = py * w / panh;
	*sy = (panw - 1 - px) * h / panw;
}

static int
reg_read(uint16_t reg, uint8_t *buf, size_t n)
{
	uint8_t a[2] = { (uint8_t)(reg >> 8), (uint8_t)(reg & 0xff) };

	return i2c_master_transmit_receive(tp, a, sizeof a, buf, n, 50) ==
	    ESP_OK ? 0 : -1;
}

static int
reg_write8(uint16_t reg, uint8_t v)
{
	uint8_t b[3] = { (uint8_t)(reg >> 8), (uint8_t)(reg & 0xff), v };

	return i2c_master_transmit(tp, b, sizeof b, 50) == ESP_OK ? 0 : -1;
}

int
esp_touch_present(void)
{
	i2c_device_config_t dev = {
		.dev_addr_length = I2C_ADDR_BIT_LEN_7,
		.device_address = TDECK_TOUCH_ADDR,
		.scl_speed_hz = 400000,
	};
	i2c_master_bus_handle_t bh;
	uint8_t id[4];

	if (probed)
		return present;
	probed = 1;

	if (esp_tdeck_i2c(&bh) != 0)
		return 0;
	if (i2c_master_bus_add_device(bh, &dev, &tp) != ESP_OK)
		return 0;

	/* the product id reads as the ascii "911", which is what tells a
	 * GT911 apart from whatever else answers at this address.
	 */
	if (reg_read(GT911_PRODUCT_ID, id, sizeof id) != 0)
		return 0;
	if (id[0] != '9' || id[1] != '1' || id[2] != '1')
		return 0;

	/* the panel's resolution, so to_screen scales rather than assumes.
	 * A controller that will not say keeps the built-in guess: wrong
	 * by a scale factor beats reporting nothing at all.
	 */
	{
		uint8_t r[2];

		if (reg_read(GT911_XMAX, r, sizeof r) == 0 &&
		    (r[0] | (r[1] << 8)) > 0)
			panw = r[0] | (r[1] << 8);
		if (reg_read(GT911_YMAX, r, sizeof r) == 0 &&
		    (r[0] | (r[1] << 8)) > 0)
			panh = r[0] | (r[1] << 8);
	}

	present = 1;
	return 1;
}

int
esp_touch_poll(void)
{
	static int64_t last_us;
	int64_t now;
	uint8_t st, p[8];
	int changed = 0;

	/* probed on the first poll rather than at boot: the panel is not
	 * needed to reach a prompt, and this way a board without one costs
	 * a single failed read.
	 */
	if (!esp_touch_present())
		return 0;

	now = esp_timer_get_time();
	if (now - last_us < TOUCH_POLL_US)
		return 0;
	last_us = now;

	if (reg_read(GT911_STATUS, &st, 1) != 0)
		return 0;
	if ((st & 0x80) == 0)
		return 0;		/* no new frame */

	if ((st & 0x0f) > 0 && reg_read(GT911_POINT1, p, sizeof p) == 0) {
		int x, y;

		/* stored in screen coordinates, not the panel's: everything
		 * above this file thinks in the display's frame, and one
		 * place to get the transform wrong is better than two.
		 */
		to_screen(p[0] | (p[1] << 8), p[2] | (p[3] << 8), &x, &y);

		if (x != curx || y != cury || !curdown)
			changed = 1;
		curx = x;
		cury = y;
		curdown = 1;
	} else if (curdown) {
		curdown = 0;
		changed = 1;
	}

	/* cleared whatever happened above: a frame left unacknowledged
	 * stops the controller reporting, so a failed point read must not
	 * take the panel with it.
	 */
	reg_write8(GT911_STATUS, 0);
	return changed;
}

void
esp_touch_state(int *x, int *y, int *down)
{
	if (x)
		*x = curx;
	if (y)
		*y = cury;
	if (down)
		*down = curdown;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */
