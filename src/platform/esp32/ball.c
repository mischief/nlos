/* the T-Deck's trackball, driven as a scroll wheel.
 *
 * Four pins, one per direction. Vertical is plan 9's wheel, 8 and 16.
 * Horizontal has no plan 9 bits and follows x11's buttons 6 and 7.
 *
 * Counted in an interrupt rather than polled. A pulse is short and a
 * fast spin makes many, so a 10ms poll would see a fraction of them;
 * an edge count is also the whole of what an isr can do here without
 * touching a bus, unlike the touch panel next door.
 *
 * TB_THRESHOLD pulses make one click, which is the ball's own
 * resolution: one detent is several edges, and reporting each would
 * scroll a page for a nudge.
 *
 * A click is momentary, and that is why the counts are handed out one
 * per call rather than as a level. Two clicks between two reads are two
 * records, never one -- a wheel that coalesces is a wheel that loses
 * scrolling, which is exactly what the position half of a mouse record
 * is allowed to do and this half is not.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/gpio.h>
#include <esp_attr.h>

#include "ball.h"
#include "esp32.h"

/* Wiring from the LilyGo reference and meshtastic's variant, which
 * agree. The press shares GPIO 0 with the strapping pin the rom reads
 * at reset; it is an ordinary input once running.
 */
#define TB_UP		3
#define TB_DOWN		15
#define TB_LEFT		1
#define TB_RIGHT	2
#define TB_PRESS	0

/* pulses to a click. The ball's own detent is several edges. */
#define TB_THRESHOLD	3

static int probed, present;
static volatile unsigned upn, downn, leftn, rightn;
static int held;

/* one counter per direction, incremented per falling edge. Nothing
 * here allocates, takes a lock or touches a bus, which is what lets it
 * be an isr at all.
 */
static void IRAM_ATTR
ball_isr(void *arg)
{
	switch ((int)(intptr_t)arg) {
	case TB_UP:
		upn++;
		break;
	case TB_DOWN:
		downn++;
		break;
	case TB_LEFT:
		leftn++;
		break;
	default:
		rightn++;
		break;
	}
}

int
esp_ball_present(void)
{
	gpio_config_t rot = {
		.pin_bit_mask = (1ULL << TB_UP) | (1ULL << TB_DOWN) |
		    (1ULL << TB_LEFT) | (1ULL << TB_RIGHT),
		.mode = GPIO_MODE_INPUT,
		.pull_up_en = GPIO_PULLUP_ENABLE,
		.intr_type = GPIO_INTR_NEGEDGE,
	};
	gpio_config_t btn = {
		.pin_bit_mask = 1ULL << TB_PRESS,
		.mode = GPIO_MODE_INPUT,
		.pull_up_en = GPIO_PULLUP_ENABLE,
		.intr_type = GPIO_INTR_DISABLE,
	};

	if (probed)
		return present;
	probed = 1;

	if (gpio_config(&rot) != ESP_OK || gpio_config(&btn) != ESP_OK)
		return 0;

	if (esp_gpio_isr() != 0)
		return 0;

	if (gpio_isr_handler_add(TB_UP, ball_isr, (void *)TB_UP) != ESP_OK)
		return 0;
	if (gpio_isr_handler_add(TB_DOWN, ball_isr, (void *)TB_DOWN) != ESP_OK)
		return 0;
	if (gpio_isr_handler_add(TB_LEFT, ball_isr, (void *)TB_LEFT) != ESP_OK)
		return 0;
	if (gpio_isr_handler_add(TB_RIGHT, ball_isr,
	    (void *)TB_RIGHT) != ESP_OK)
		return 0;

	present = 1;
	return 1;
}

int
esp_ball_take(int *wheel, int *button)
{
	int down;

	if (!esp_ball_present())
		return 0;

	/* the press first, because it is state and a click is a queue:
	 * a button change waiting behind a spin is a button that reports
	 * late or, while the ball keeps turning, not at all. Pressing
	 * this ball turns it a little, so that is the ordinary case
	 * rather than the awkward one.
	 */
	down = gpio_get_level(TB_PRESS) == 0;
	if (down != held) {
		held = down;
		*wheel = 0;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}

	/* one click per call, so a spin arrives as several records. The
	 * counter is only ever decremented here and incremented in the
	 * isr, so a click landing between the test and the subtraction
	 * is kept rather than lost.
	 */
	if (upn >= TB_THRESHOLD) {
		upn -= TB_THRESHOLD;
		*wheel = BALL_UP;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}
	if (downn >= TB_THRESHOLD) {
		downn -= TB_THRESHOLD;
		*wheel = BALL_DOWN;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}
	if (leftn >= TB_THRESHOLD) {
		leftn -= TB_THRESHOLD;
		*wheel = BALL_LEFT;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}
	if (rightn >= TB_THRESHOLD) {
		rightn -= TB_THRESHOLD;
		*wheel = BALL_RIGHT;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}

	return 0;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */
