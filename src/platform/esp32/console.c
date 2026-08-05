/* the console is IDF's, whichever link sdkconfig pointed it at: UART0
 * under qemu, the native USB-Serial-JTAG on a T-Deck. Going through
 * stdio rather than a driver keeps one code path for both, which
 * matters because those are the two machines this platform runs on and
 * they do not agree on the hardware.
 *
 * Unlike efi there is no second port here yet, so this is the console
 * and there is no 9p wire to share it with. When one arrives it will
 * have to be arbitrated the way microvm does it, through
 * platform_console_input.
 */

#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <unistd.h>

#include <sdkconfig.h>
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
#include <driver/usb_serial_jtag.h>
#include <driver/usb_serial_jtag_vfs.h>
#endif

#include "esp32.h"
#include "platform.h"

void
console_init(void)
{
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	/* The USB-Serial-JTAG console can write without any of this, but it
	 * cannot read: the default VFS binding is the ROM one, which has no
	 * receive path, so stdin returns nothing forever and the host's
	 * writes block once the CDC buffer fills. Installing the driver and
	 * pointing the VFS at it is what makes the port bidirectional.
	 *
	 * The symptom is worth recognising: output looks perfect, so the
	 * console appears to work and only typing is dead.
	 */
	usb_serial_jtag_driver_config_t cfg =
	    USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();

	if (usb_serial_jtag_driver_install(&cfg) == ESP_OK)
		usb_serial_jtag_vfs_use_driver();
#endif

	/* Unbuffered both ways. Output because a line-buffered console
	 * loses whatever a panic was mid-way through printing, which is
	 * exactly the output worth having; input because the kernel polls
	 * for a byte and stdio would sit on it waiting for a newline.
	 */
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stdin, NULL, _IONBF, 0);

	int fl = fcntl(STDIN_FILENO, F_GETFL, 0);

	if (fl >= 0)
		fcntl(STDIN_FILENO, F_SETFL, fl | O_NONBLOCK);
}

/* bare \n becomes \r\n, for the same reason microvm's console does it:
 * a terminal on a serial line does not return the carriage on a line
 * feed, so unix line endings walk the text off to the right.
 */
void
console_write(const char *s, size_t n)
{
	size_t start = 0;

	for (size_t i = 0; i < n; i++) {
		if (s[i] != '\n')
			continue;
		if (i > start)
			fwrite(s + start, 1, i - start, stdout);
		fwrite("\r\n", 1, 2, stdout);
		start = i + 1;
	}
	if (n > start)
		fwrite(s + start, 1, n - start, stdout);
	fflush(stdout);
}

/* one character of pushback, so console_peek can answer without
 * consuming. Not a ring: the only caller that peeks is the idle path,
 * and it reads the byte on the very next lap.
 */
static int pushback = -1;

int
console_peek(void)
{
	unsigned char c;

	if (pushback >= 0)
		return 1;
	if (read(STDIN_FILENO, &c, 1) == 1) {
		pushback = c;
		return 1;
	}
	return 0;
}

int
console_getchar(void)
{
	unsigned char c;

	if (pushback >= 0) {
		int v = pushback;

		pushback = -1;
		return v;
	}
	if (read(STDIN_FILENO, &c, 1) == 1)
		return c;
	return -1;
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
