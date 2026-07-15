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

/* blocking keystroke, echoed, cr -> lf. ctrl-d gives EOF (-1). backs
 * libc stdin (getc). NOTE: the kernel kbd pump also drains ConIn, so
 * this and port-based keyboard input must not be used at the same time
 * -- they steal keystrokes from each other.
 */
int
console_getchar(void)
{
	EFI_INPUT_KEY key;
	UINTN index;

	for (;;) {
		while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) !=
		    EFI_SUCCESS)
			BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
		if (key.UnicodeChar == 0)
			continue;	/* function keys etc */
		if (key.UnicodeChar == 0x04)
			return -1;
		if (key.UnicodeChar == '\r') {
			console_write("\n", 1);
			return '\n';
		}
		if (key.UnicodeChar < 0x80) {
			char c = (char)key.UnicodeChar;

			console_write(&c, 1);
			return c;
		}
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
