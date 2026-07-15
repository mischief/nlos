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

/* blocking keystroke, echoed, cr -> lf. ctrl-d gives EOF (-1). */
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

/* line editor: echo, backspace. returns length, or -1 on ctrl-d
 * at an empty line.
 */
int
console_readline(char *buf, int cap)
{
	int len = 0;
	EFI_INPUT_KEY key;
	UINTN index;

	for (;;) {
		while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) !=
		    EFI_SUCCESS)
			BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);

		CHAR16 c = key.UnicodeChar;

		if (c == 0x04 && len == 0)
			return -1;
		if (c == '\r') {
			console_write("\n", 1);
			buf[len] = 0;
			return len;
		}
		if (c == 0x08 || c == 0x7f) {
			if (len > 0) {
				len--;
				console_write("\b \b", 3);
			}
			continue;
		}
		if (c >= 0x20 && c < 0x80 && len < cap - 1) {
			buf[len++] = (char)c;
			char e = (char)c;

			console_write(&e, 1);
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
