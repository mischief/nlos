/* the console is the same wire as com1: one ISA serial port, no
 * firmware console to separate from it (contrast src/platform/efi/
 * console.c, which is ST->ConOut/ConIn).
 */

#include <stddef.h>

#include "platform.h"
#include "microvm.h"

/* bare \n becomes \r\n on the way out.
 *
 * A terminal on the far end of a serial line does not move the carriage
 * for a line feed, so text written with unix line endings walks off to
 * the right one line at a time -- unmissable on a vmd console, and
 * invisible under the test harness, which strips \r before comparing.
 *
 * Here and not in uart_tx: com1 also carries the 9p wire (lib/wire.lua),
 * and rewriting bytes in a protocol stream would corrupt it. This is the
 * console, where the convention belongs.
 */
void
console_write(const char *s, size_t n)
{
	size_t start = 0;

	/* one line, not one segment: the loop below makes several calls
	 * per string and another cpu's console_write must not land in
	 * the middle of them.
	 */
	uart_txlock();
	for (size_t i = 0; i < n; i++) {
		if (s[i] != '\n')
			continue;
		if (i > start)
			uart_tx(s + start, i - start);
		uart_tx("\r\n", 2);
		start = i + 1;
	}
	if (n > start)
		uart_tx(s + start, n - start);
	uart_txunlock();
}

int
console_getchar(void)
{
	return uart_rx();
}

/* no firmware, no watchdog. */
void
platform_watchdog(unsigned secs)
{
	(void)secs;
}

_Noreturn void
platform_abort(const char *why)
{
	console_write("PANIC: ", 7);
	if (why)
		console_write(why, __builtin_strlen(why));
	console_write("\n", 1);
	machine_halt();
}
