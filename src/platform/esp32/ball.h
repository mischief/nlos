/* the T-Deck's trackball, as a scroll wheel. */

#ifndef LUAOS_ESP32_BALL_H
#define LUAOS_ESP32_BALL_H

/* wheel bits, plan 9's: a click is momentary and appears in the button
 * field of one mouse record.
 */
#define BALL_UP		8
#define BALL_DOWN	16
/* the other axis. plan 9 names no bits for it, so these follow x11,
 * where horizontal scroll is buttons 6 and 7.
 */
#define BALL_LEFT	32
#define BALL_RIGHT	64
/* the ball's press is button 2, which the panel cannot otherwise send:
 * the pointer is positioned by touching, and a touch is already button
 * 1, so a press reporting 1 says what the touch that aimed it just
 * said. The record carries the last touch position, not the ball's.
 */
#define BALL_BUTTON	2

/* set the pins up once; 1 if the board has a ball. */
int esp_ball_present(void);

/* one pending event, or 0.
 *
 * *wheel is one of the four click bits and 0 otherwise, *button is
 * BALL_BUTTON while the ball is held. Clicks are counted by the
 * interrupt and handed out one per call, so a fast scroll arrives as
 * several records rather than as one that lost the rest.
 */
int esp_ball_take(int *wheel, int *button);

#endif
