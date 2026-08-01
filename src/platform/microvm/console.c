/* the console is the same wire as com1: one ISA serial port, no
 * firmware console to separate from it (contrast src/platform/efi/
 * console.c, which is ST->ConOut/ConIn).
 */

#include <stddef.h>

#include "platform.h"

void
console_write(const char *s, size_t n)
{
	uart_tx(s, n);
}

int
console_getchar(void)
{
	return uart_rx();
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
