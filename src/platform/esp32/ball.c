/* the T-Deck's trackball, driven as a scroll wheel.
 *
 * The ball reports rotation as pulses on four pins, one per direction.
 * Only the two vertical ones are used, and they become plan 9's wheel
 * buttons: 8 for up, 16 for down. That is a decision about what the
 * hardware is for rather than a limitation -- a pointer is already
 * here, absolute and under your finger, and what the panel lacks is a
 * way to move a page without covering it. A scroll wheel is the thing
 * every list, pager and document already knows how to be driven by.
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
static volatile unsigned upn, downn;
static int held;

/* one counter per direction, incremented per falling edge. Nothing
 * here allocates, takes a lock or touches a bus, which is what lets it
 * be an isr at all.
 */
static void IRAM_ATTR
ball_isr(void *arg)
{
	if ((int)(intptr_t)arg == TB_UP)
		upn++;
	else
		downn++;
}

int
esp_ball_present(void)
{
	gpio_config_t rot = {
		.pin_bit_mask = (1ULL << TB_UP) | (1ULL << TB_DOWN),
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
	esp_err_t e;

	if (probed)
		return present;
	probed = 1;

	if (gpio_config(&rot) != ESP_OK || gpio_config(&btn) != ESP_OK)
		return 0;

	/* the service may already be installed by another driver; that
	 * is not a failure, it is the second caller.
	 */
	e = gpio_install_isr_service(0);
	if (e != ESP_OK && e != ESP_ERR_INVALID_STATE)
		return 0;

	if (gpio_isr_handler_add(TB_UP, ball_isr, (void *)TB_UP) != ESP_OK)
		return 0;
	if (gpio_isr_handler_add(TB_DOWN, ball_isr, (void *)TB_DOWN) != ESP_OK)
		return 0;

	/* left and right are wired and deliberately unread: this is a
	 * wheel, and a wheel has one axis.
	 */
	(void)TB_LEFT;
	(void)TB_RIGHT;

	present = 1;
	return 1;
}

int
esp_ball_take(int *wheel, int *button)
{
	int down;

	if (!esp_ball_present())
		return 0;

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

	/* the press, low when held. Reported only when it changes: it is
	 * state, unlike a click.
	 */
	down = gpio_get_level(TB_PRESS) == 0;
	if (down != held) {
		held = down;
		*wheel = 0;
		*button = held ? BALL_BUTTON : 0;
		return 1;
	}
	return 0;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */
