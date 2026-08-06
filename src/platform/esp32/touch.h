/* the T-Deck's touch panel: a GT911 on the shared i2c bus. */

#ifndef LUAOS_ESP32_TOUCH_H
#define LUAOS_ESP32_TOUCH_H

/* probe once; 1 if a touch controller answered. */
int esp_touch_present(void);

/* read the panel from the idle path, at most every TOUCH_POLL_US.
 * 1 when the position or the button changed since the last poll.
 */
int esp_touch_poll(void);

/* the current position, and whether a finger is down. Coordinates are
 * the display's, not the panel's.
 */
void esp_touch_state(int *x, int *y, int *down);

/* the same, but only when it has changed since the last call: 1 and the
 * three filled, or 0. This is what the kernel's pump asks, so a lap
 * with a still finger costs one comparison and pushes nothing.
 */
int esp_touch_take(int *x, int *y, int *down);

#endif
