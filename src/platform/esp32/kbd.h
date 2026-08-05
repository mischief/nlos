/* the Cardputer's built-in keyboard, as characters.
 *
 * Not the console: the serial port stays the console (task/cons.lua),
 * and this is the input half of a second terminal -- a proc that
 * answers {op="write"} and {op="readline"} exactly as cons, sshd and
 * webterm each already do. See task/sshd.lua's header: a shell does not
 * know what its console IS, so a fourth implementation needs no changes
 * above it.
 */
#ifndef ESP32_KBD_H
#define ESP32_KBD_H

int esp_kbd_present(void);	/* probe once; wires the matrix gpios */
int esp_kbd_poll(void);		/* scan from the idle path; 1 if a key landed */
int esp_kbd_read(void);		/* take a buffered character, or 0 */
unsigned long esp_kbd_irqs(void);	/* changes when a key lands */

#endif
