/* the console: two host imports and a newline rule.
 *
 * A wasm host has no terminal to put in raw mode, so raw here only
 * decides whether a bare \n is rewritten on the way out. An embedder
 * driving a real terminal does that translation itself.
 */

#include <stddef.h>

#include "host.h"
#include "platform.h"

static int rawmode;

void
console_setraw(int on)
{
	rawmode = on;
}

void
console_write(const char *s, size_t n)
{
	size_t start = 0;

	if (rawmode) {
		host_write(s, n);
		return;
	}
	for (size_t i = 0; i < n; i++) {
		if (s[i] != '\n')
			continue;
		host_write(s + start, i - start);
		host_write("\r\n", 2);
		start = i + 1;
	}
	if (start < n)
		host_write(s + start, n - start);
}

int
console_getchar(void)
{
	return host_read();
}

/* the second serial port, which this machine does not have. kernel.c
 * drives one unconditionally; here it is a port with nothing on it.
 */
void
uart_init(void)
{
}

void
uart_poll(void)
{
}

int
uart_rx(void)
{
	return -1;
}

void
uart_tx(const char *s, unsigned long n)
{
	(void)s;
	(void)n;
}
