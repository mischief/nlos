#ifndef ESP32_H
#define ESP32_H

/* esp32-local platform bits, kept out of src/platform.h because no
 * other platform has an opinion about them.
 */

/* set up the IDF console for the way kernel.c uses it: unbuffered, and
 * non-blocking on input, because pump_serial polls rather than parks.
 */
void	console_init(void);

/* is a byte already there? The idle path needs to distinguish "nothing
 * to do, sleep until the tick" from "a key arrived", and console_getchar
 * would consume the byte it is asking about. Buffers one character.
 */
int	console_peek(void);

/* publish the embedded set to newlib's fopen, which is what lua's
 * luaL_loadfile and the path searcher use. See vfs.c for why this is
 * needed here and on no other platform.
 */
void	vfs_embed_register(void);

#endif
