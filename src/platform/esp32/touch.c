/* the T-Deck's touch panel: a GT911 at 0x5d on the shared i2c bus. */

/* State, not a stream: one position and a changed flag, nothing queued.
 * A reader that falls behind wants where the finger is now, so it lags
 * in resolution rather than in time, as plan 9's mouse file does.
 */

/* TDECK_TOUCH_INT says a frame is ready. An isr cannot do i2c, so it
 * raises a flag and the read happens in the poll below -- the pin is
 * not there to make the read faster, it is there so the bus is left
 * alone while nothing is touching the panel.
 */

/* Register map: a 16-bit big-endian register address, 0x814e holding
 * the buffer status (bit 7) and the number of points (low nibble), and
 * the first point at 0x8150 as x, y and size, each a little-endian
 * pair.
 */

/* The track id at 0x814f sits below the coordinates, not in front of
 * them: read as the first byte of the point it shifts every field by
 * one and gives coordinates in the tens of thousands. And the status
 * must be written back as zero or no further frame is reported.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/gpio.h>
#include <driver/i2c_master.h>
#include <esp_timer.h>
#include <stdint.h>
#include <stdio.h>

#include "esp32.h"
#include "lcd.h"
#include "touch.h"
#include "kernel.h"

#define GT911_PRODUCT_ID	0x8140
#define GT911_XMAX		0x8048	/* config: resolution, little-endian */
#define GT911_YMAX		0x804a
#define GT911_STATUS		0x814e
#define GT911_POINT1		0x8150

/* The controller raises TDECK_TOUCH_INT when it has a frame, so the bus
 * is read when there is something to read. The backstop runs if that
 * pin never fires: a board wired differently still works, late.
 */
#define TOUCH_POLL_US		10000
#define TOUCH_BACKSTOP_US	100000

/* raised by the pin, cleared by the read it provokes. An isr cannot do
 * i2c, so this is all it can do and all it needs to.
 */
static volatile int pending;

static void
touch_isr(void *arg)
{
	(void)arg;
	pending = 1;
}

static i2c_master_dev_handle_t tp;
static int probed, present;
static int curx, cury, curdown;

/* set when the state above changes and cleared by esp_touch_take:
 * the kernel pumps this port on every lap, and a still finger must
 * cost a comparison rather than a message.
 */
static int dirty;

/* the panel's own resolution, from its config registers. It is mounted
 * in portrait under a display driven landscape, so this is 240x320
 * against the screen's 320x240 -- read rather than assumed, since the
 * numbers that would be wrong are exactly the ones nothing else checks.
 */
static int panw = 240, panh = 320;

/* panel to screen. lcd.c uses swap_xy and mirror_x and the controller
 * reports in the glass's frame, so the axes trade places and one counts
 * backwards. The screen's top left reads as panel (218, 16).
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

	/* absent and broken look the same from above -- the machine comes
	 * up without a pointer either way -- so each way of failing says
	 * so once.
	 */
	if (esp_tdeck_i2c(&bh) != 0) {
		kernel_log("touch: no i2c bus");
		return 0;
	}
	if (i2c_master_bus_add_device(bh, &dev, &tp) != ESP_OK) {
		kernel_log("touch: 0x5d would not attach to the bus");
		return 0;
	}

	/* the product id reads as the ascii "911", which is what tells a
	 * GT911 apart from whatever else answers at this address.
	 */
	if (reg_read(GT911_PRODUCT_ID, id, sizeof id) != 0) {
		char m[96];
		int n = snprintf(m, sizeof m, "touch: no answer at 0x5d; bus has");
		int a;

		/* which addresses do answer, since a silent panel and a
		 * silent bus want different repairs: the keyboard's C3 at
		 * 0x55 is the other device on these wires.
		 */
		for (a = 0x08; a < 0x78 && n < (int)sizeof m - 6; a++) {
			if (i2c_master_probe(bh, a, 50) == ESP_OK)
				n += snprintf(m + n, sizeof m - n, " %02x", a);
		}
		kernel_log(m);
		return 0;
	}
	if (id[0] != '9' || id[1] != '1' || id[2] != '1') {
		char m[64];

		snprintf(m, sizeof m, "touch: 0x5d is not a GT911: %02x%02x%02x",
		    id[0], id[1], id[2]);
		kernel_log(m);
		return 0;
	}

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

	/* the frame-ready pin. Its absence is not fatal: the backstop
	 * above keeps the panel working, slower.
	 */
	{
		gpio_config_t irq = {
			.pin_bit_mask = 1ULL << TDECK_TOUCH_INT,
			.mode = GPIO_MODE_INPUT,
			.pull_up_en = GPIO_PULLUP_ENABLE,
			.intr_type = GPIO_INTR_NEGEDGE,
		};
		if (esp_gpio_isr() == 0 && gpio_config(&irq) == ESP_OK)
			gpio_isr_handler_add(TDECK_TOUCH_INT, touch_isr, NULL);
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
	if (!pending && now - last_us < TOUCH_BACKSTOP_US)
		return 0;
	pending = 0;
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
	if (changed)
		dirty = 1;
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

int
esp_touch_take(int *x, int *y, int *down)
{
	if (!dirty)
		return 0;
	dirty = 0;
	esp_touch_state(x, y, down);
	return 1;
}

#else /* CONFIG_LUAOS_BOARD_TDECK */

/* a board with no panel answers that it has none, the way every other
 * probe here does. The idle path calls poll unconditionally, so these
 * have to exist for it to link.
 */
int
esp_touch_present(void)
{
	return 0;
}

int
esp_touch_poll(void)
{
	return 0;
}

void
esp_touch_state(int *x, int *y, int *down)
{
	if (x)
		*x = 0;
	if (y)
		*y = 0;
	if (down)
		*down = 0;
}

int
esp_touch_take(int *x, int *y, int *down)
{
	(void)x;
	(void)y;
	(void)down;
	return 0;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */
