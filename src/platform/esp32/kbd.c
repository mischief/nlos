/* the Cardputer's keyboard: a 74HC138 3-to-8 decoder selects one of
 * eight columns, seven gpios read the rows, active low.
 *
 * Pin map, keymaps and the scan are from
 * clm's esp32 firmware (board_cardputer.c), which is the tested
 * source for this board. The grid arithmetic is the part worth not
 * rederiving: selects 4..7 address the odd x columns and 0..3 the even
 * ones, and y counts down from 3.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_CARDPUTER

#include <stdint.h>

#include <driver/gpio.h>
#include <esp_rom_sys.h>
#include <esp_timer.h>

#include "kbd.h"

static const int kb_out[3] = { 8, 9, 11 };		/* 74HC138 select */
static const int kb_in[7] = { 13, 15, 3, 4, 5, 6, 7 };	/* row reads */

static const uint8_t kb_x1[7] = { 0, 2, 4, 6, 8, 10, 12 };
static const uint8_t kb_x2[7] = { 1, 3, 5, 7, 9, 11, 13 };

static const char kb_base[4][14] = {
	{ '`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b' },
	{ '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\\' },
	{ 0, 0, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '\n' },
	{ 0, 0, 0, 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', ' ' },
};

static const char kb_shift[4][14] = {
	{ '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '\b' },
	{ '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '|' },
	{ 0, 0, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '\n' },
	{ 0, 0, 0, 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', ' ' },
};

#define KB_SHIFT_X 1
#define KB_SHIFT_Y 2

static int ready;

/* Keys found by esp_kbd_poll, waiting for a reader.
 *
 * Small on purpose: this holds keystrokes between one idle lap and the
 * next, not a typeahead buffer. A human cannot outrun it, and a full
 * ring means the consumer is not running at all, in which case dropping
 * is the honest outcome.
 */
static char ring[16];
static unsigned rhead, rtail;
static unsigned long irqs;

static void
kb_select(uint8_t v)
{
	gpio_set_level(kb_out[0], v & 1);
	gpio_set_level(kb_out[1], (v >> 1) & 1);
	gpio_set_level(kb_out[2], (v >> 2) & 1);
}

int
esp_kbd_present(void)
{
	gpio_config_t out = {
		.pin_bit_mask = (1ULL << kb_out[0]) | (1ULL << kb_out[1]) |
		    (1ULL << kb_out[2]),
		.mode = GPIO_MODE_OUTPUT,
	};
	gpio_config_t in = {
		.mode = GPIO_MODE_INPUT,
		.pull_up_en = GPIO_PULLUP_ENABLE,
	};
	int i;

	if (ready)
		return 1;

	for (i = 0; i < 7; i++)
		in.pin_bit_mask |= 1ULL << kb_in[i];

	if (gpio_config(&out) != ESP_OK || gpio_config(&in) != ESP_OK)
		return 0;

	kb_select(0);
	ready = 1;
	return 1;
}

/* One scan, debounced in time rather than in scans.
 *
 * A held key must not repeat, and the obvious latch -- remember the
 * cell, clear it the moment a scan reads nothing -- is wrong for a
 * caller that polls fast. A single scan that misses the key to contact
 * bounce re-arms the latch and the next one fires again: measured as
 * "aaaa" and "......." from one press each, polling in a tight loop.
 * Scanning once per frame hides it, which is why the source this came
 * from does not need this.
 *
 * So the latch clears only after the cell has read released for
 * RELEASE_US continuously. That makes the behaviour a property of the
 * keyboard rather than of how often somebody asks it.
 */
#define RELEASE_US 20000

static int
esp_kbd_read_raw(void)
{
	static int last_x = -1, last_y = -1;
	static int64_t seen_us;		/* when the latched cell last read down */
	int64_t now = esp_timer_get_time();
	int held = 0;
	int px[8], py[8], n = 0;
	int shift = 0;
	int i, j, k, cx = -1, cy = -1;
	char ch = 0;

	if (!ready)
		return 0;

	for (i = 0; i < 8 && n < 8; i++) {
		kb_select((uint8_t)i);
		esp_rom_delay_us(3);	/* 74HC138 + inputs settle */
		for (j = 0; j < 7; j++) {
			int x, y;

			if (gpio_get_level(kb_in[j]) != 0)
				continue;	/* active low */
			x = (i > 3) ? kb_x1[j] : kb_x2[j];
			y = 3 - ((i > 3) ? (i - 4) : i);
			if (x == KB_SHIFT_X && y == KB_SHIFT_Y)
				shift = 1;
			if (n < 8) {
				px[n] = x;
				py[n] = y;
				n++;
			}
		}
	}

	/* is the latched cell still down, whatever else is? checked over
	 * every pressed cell rather than only the first that maps to a
	 * character, so a second key going down does not look like the
	 * first coming up.
	 */
	for (k = 0; k < n; k++)
		if (px[k] == last_x && py[k] == last_y)
			held = 1;

	if (held)
		seen_us = now;

	for (k = 0; k < n; k++) {
		char c = shift ? kb_shift[py[k]][px[k]] : kb_base[py[k]][px[k]];

		if (c != 0) {
			cx = px[k];
			cy = py[k];
			ch = c;
			break;
		}
	}

	if (ch == 0) {		/* only modifiers, or nothing down */
		if (!held && now - seen_us > RELEASE_US)
			last_x = last_y = -1;
		return 0;
	}
	if (cx == last_x && cy == last_y)
		return 0;	/* the same press, still down */
	if (last_x >= 0 && held)
		return 0;	/* a different key while the last is still down */

	last_x = cx;
	last_y = cy;
	seen_us = now;
	return (unsigned char)ch;
}

/* Scan from the idle path, so nothing in lua has to poll.
 *
 * The matrix cannot interrupt: a 74HC138 drives exactly one column low
 * and the other seven actively high, so a key outside the selected
 * column cannot pull its row down. There is no "any key" line to arm.
 * Scanning is therefore forced by the hardware -- but it belongs here,
 * where the machine is already awake and about to sleep, rather than in
 * a task that would have to spin or wake on a timer.
 *
 * Rate limited because the shim's wait loop turns over every 1ms and a
 * scan is 56.6us measured: unthrottled that is 5.7% of the core spent
 * looking at a keyboard nobody pressed. At 8ms it is 0.7%, still far
 * below how long a key stays down, and below the debounce window that
 * decides repeats anyway.
 */
#define KBD_SCAN_US 8000

int
esp_kbd_poll(void)
{
	static int64_t last_us;
	int64_t now;
	unsigned next;
	int c;

	if (!ready)
		return 0;

	now = esp_timer_get_time();
	if (now - last_us < KBD_SCAN_US)
		return 0;
	last_us = now;

	c = esp_kbd_read_raw();
	if (c == 0)
		return 0;

	next = (rhead + 1) % sizeof ring;
	if (next == rtail)
		return 0;		/* nobody is draining; drop */
	ring[rhead] = (char)c;
	rhead = next;
	irqs++;
	return 1;
}

/* what the kernel compares each lap to decide a device did something.
 * Not an interrupt count -- there are none here -- but it serves the
 * same purpose: a number that changes when there is work.
 */
unsigned long
esp_kbd_irqs(void)
{
	return irqs;
}

int
esp_kbd_read(void)
{
	int c;

	if (rtail == rhead)
		return 0;
	c = (unsigned char)ring[rtail];
	rtail = (rtail + 1) % sizeof ring;
	return c;
}

#elif CONFIG_LUAOS_BOARD_TDECK

/* the T-Deck's keyboard is a microcontroller of its own -- an ESP32-C3
 * on i2c at 0x55 -- so almost nothing is left to do here. A one-byte
 * read hands back the ascii of the last key, or zero for none: the
 * scanning, the debounce and the modifier handling all happen on the
 * far side. Contrast kbd.c's Cardputer half, which drives a 74HC138
 * and owns all three.
 *
 * Polled from the idle path rather than driven off TDECK_KB_INT. The
 * interrupt exists and would work, but an i2c read cannot happen in an
 * isr -- it would only set a flag for this same poll to notice -- and
 * one register read every 8ms costs less than the machinery would. If
 * the board ever sleeps between keys that trade changes, and the pin is
 * why it can.
 */

#include <driver/i2c_master.h>
#include <esp_timer.h>

#include "esp32.h"
#include "kbd.h"

static i2c_master_dev_handle_t kb;
static int probed;
static int present;
static unsigned long irqs;

static char ring[16];
static unsigned rhead, rtail;

int
esp_kbd_present(void)
{
	i2c_master_bus_config_t bus = {
		.i2c_port = -1,
		.sda_io_num = TDECK_I2C_SDA,
		.scl_io_num = TDECK_I2C_SCL,
		.clk_source = I2C_CLK_SRC_DEFAULT,
		.glitch_ignore_cnt = 7,
		.flags.enable_internal_pullup = true,
	};
	i2c_device_config_t dev = {
		.dev_addr_length = I2C_ADDR_BIT_LEN_7,
		.device_address = TDECK_KB_ADDR,
		.scl_speed_hz = 100000,
	};
	i2c_master_bus_handle_t bh;

	if (probed)
		return present;
	probed = 1;

	/* the keyboard's own controller boots off the switched rail, so
	 * this has to come first or it simply does not answer.
	 */
	if (esp_tdeck_power_on() != 0)
		return 0;
	if (i2c_new_master_bus(&bus, &bh) != ESP_OK)
		return 0;
	if (i2c_master_bus_add_device(bh, &dev, &kb) != ESP_OK)
		return 0;
	present = 1;
	return 1;
}

#define KBD_POLL_US 8000

int
esp_kbd_poll(void)
{
	static int64_t last_us;
	int64_t now = esp_timer_get_time();
	uint8_t v = 0;
	unsigned next;

	if (!present)
		return 0;
	if (now - last_us < KBD_POLL_US)
		return 0;
	last_us = now;

	/* a short timeout: this runs on the idle path, and a keyboard
	 * that has stopped answering must not stall the machine.
	 */
	if (i2c_master_receive(kb, &v, 1, 20) != ESP_OK || v == 0)
		return 0;

	next = (rhead + 1) % sizeof ring;
	if (next == rtail)
		return 0;		/* full; drop rather than block */
	ring[rhead] = (char)v;
	rhead = next;
	irqs++;
	return 1;
}

unsigned long
esp_kbd_irqs(void)
{
	return irqs;
}

int
esp_kbd_read(void)
{
	int c;

	if (rtail == rhead)
		return 0;
	c = (unsigned char)ring[rtail];
	rtail = (rtail + 1) % sizeof ring;
	return c;
}

#else /* neither board */


int
esp_kbd_poll(void)
{
	return 0;
}

unsigned long
esp_kbd_irqs(void)
{
	return 0;
}

int
esp_kbd_present(void)
{
	return 0;
}

int
esp_kbd_read(void)
{
	return 0;
}

#endif
