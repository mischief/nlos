#ifndef HOSTED_H
#define HOSTED_H

/* what the files of this platform share, and nothing above them sees. */

#include <stddef.h>

/* console.c: the terminal on fd 0/1. console_init puts a tty into raw
 * mode and registers the restore; a console on a pipe is left alone.
 */
void	console_init(void);

/* the descriptor keystrokes arrive on, for the idle poll. */
int	console_infd(void);

/* microseconds on a monotonic clock, which is also platform_ticks's
 * unit. One clock for the shim's tick, the stall and the idle timeout.
 */
unsigned long long hosted_now_us(void);

/* sleep this long, giving the cpu back for the whole of it. */
void	hosted_stall_us(unsigned long us);

/* n bytes from the host's entropy source. 0 on success. */
int	hosted_random(void *buf, size_t n);

/* the machine's memory, set once before anything allocates. */
void	hosted_setmem(unsigned long long bytes);

/* the display mode -r/--gui/--headless selected. HOSTED_GUI is only a
 * request: platform_have_fb answers no until an SDL backend exists.
 */
enum { HOSTED_HEADLESS, HOSTED_GUI };
extern int hosted_display;

#endif
