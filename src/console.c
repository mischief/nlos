/* efi text console backend for stdio */

#include <stddef.h>
#include "efi.h"

void
console_write(const char *s, size_t n)
{
	CHAR16 buf[128];
	size_t i = 0;

	while (n--) {
		char c = *s++;

		if (i >= (sizeof buf / sizeof buf[0]) - 3) {
			buf[i] = 0;
			ST->ConOut->OutputString(ST->ConOut, buf);
			i = 0;
		}
		if (c == '\n')
			buf[i++] = '\r';
		buf[i++] = (CHAR16)(unsigned char)c;
	}
	if (i) {
		buf[i] = 0;
		ST->ConOut->OutputString(ST->ConOut, buf);
	}
}

extern _Noreturn void machine_halt(void);

_Noreturn void
platform_abort(const char *why)
{
	size_t n = 0;

	while (why[n])
		n++;
	console_write("\npanic: ", 8);
	console_write(why, n);
	console_write("\n", 1);
	machine_halt();
}
