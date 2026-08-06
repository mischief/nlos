/* the T-Deck's trackball, as a scroll wheel. */

#ifndef LUAOS_ESP32_BALL_H
#define LUAOS_ESP32_BALL_H

/* wheel bits, plan 9's: a click is momentary and appears in the button
 * field of one mouse record.
 */
#define BALL_UP		8
#define BALL_DOWN	16
/* the ball's press is button 1, the same as a tap.
 *
 * They are different devices and that is not a difference a program
 * should have to know: both mean "act on the thing here", and a file
 * that reported one as button 2 would make every reader carry a rule
 * about which board it is running on. That is the knowledge /dev/mouse
 * exists to absorb.
 */
#define BALL_BUTTON	1

/* set the pins up once; 1 if the board has a ball. */
int esp_ball_present(void);

/* one pending event, or 0.
 *
 * *wheel is BALL_UP or BALL_DOWN for a click and 0 otherwise, *button
 * is BALL_BUTTON while the ball is held. Clicks are counted by the
 * interrupt and handed out one per call, so a fast scroll arrives as
 * several records rather than as one that lost the rest.
 */
int esp_ball_take(int *wheel, int *button);

#endif
