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

	/* IDF's defaults are 256 bytes each way, which is enough for a
	 * repl and not for a file transfer. ZMODEM streams 1KB subpackets
	 * out while the receiver sends headers back, and at 256 the
	 * replies are lost while we are busy writing -- measured as a
	 * transfer that works up to 2048 bytes and stalls at 3072, which
	 * looks like a protocol bug and is not one.
	 */
	cfg.tx_buffer_size = 4096;
	cfg.rx_buffer_size = 4096;

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

/* Raw mode: pass bytes through untouched.
 *
 * Not a convenience. The translation below corrupts any binary stream
 * that happens to contain 0x0a -- a ZMODEM data subpacket, for one,
 * which then fails its crc, gets asked for again and times out. The
 * handshake survives it because ZHEX headers are printable and already
 * carry their own CRLF, so the failure looks like "the transfer stalls
 * after the file is created" rather than like line endings.
 *
 * task/cons.lua's rawon says a console with nothing to switch may
 * ignore it because "platform.write is the same bytes either way".
 * That is true of the platforms it was written against and false here,
 * so this is what makes it true.
 */
static int rawmode;

/* Write straight at the driver, not through stdio.
 *
 * IDF's VFS path (usbjtag_tx_char_via_driver) tries a non-blocking
 * write, then one blocking write, and if that times out it latches
 * tx_tried_blocking and SILENTLY DROPS every byte after it. That is a
 * reasonable answer to "no host is attached" and a corrupting one when
 * a host is attached and merely slower than we are: a ZMODEM transfer
 * loses bytes mid-stream, the crc fails and the receiver asks for
 * position 0 again. Measured as transfers that work to 2048 bytes and
 * fail at 3072 -- a size threshold, which is what a filling buffer
 * looks like.
 *
 * So: loop until the driver has taken everything, with a timeout long
 * enough that a reading host always wins. Giving up after that is
 * deliberate -- a console with nobody on the other end must not wedge
 * the machine.
 */
static void
write_all(const char *s, size_t n)
{
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	size_t off = 0;
	int idle = 0;

	/* In chunks, because usb_serial_jtag_write_bytes takes at most a
	 * buffer's worth per call and answers 0 for more -- and zmodem's
	 * pull() hands over every pending subpacket at once, which is
	 * comfortably past that. Asking for the lot returned 0 and, with
	 * an earlier version of this loop that gave up on the first zero,
	 * silently dropped the write: measured as 6144 bytes in and one
	 * byte out.
	 *
	 * A zero is "no room right now", not "nobody is listening", so it
	 * is retried; only a run of them means the far end has gone away.
	 */
	while (off < n) {
		size_t want = n - off;
		int w;

		if (want > 512)
			want = 512;
		w = usb_serial_jtag_write_bytes(s + off, want,
		    pdMS_TO_TICKS(100));
		if (w > 0) {
			off += (size_t)w;
			idle = 0;
		} else if (++idle > 20) {
			return;		/* ~2s of nobody draining */
		}
	}
#else
	fwrite(s, 1, n, stdout);
	fflush(stdout);
#endif
}

void
console_setraw(int on)
{
	rawmode = on;
}

/* bare \n becomes \r\n, for the same reason microvm's console does it:
 * a terminal on a serial line does not return the carriage on a line
 * feed, so unix line endings walk the text off to the right.
 */
void
console_write(const char *s, size_t n)
{
	size_t start = 0;

	if (rawmode) {
		write_all(s, n);
		return;
	}

	for (size_t i = 0; i < n; i++) {
		if (s[i] != '\n')
			continue;
		if (i > start)
			write_all(s + start, i - start);
		write_all("\r\n", 2);
		start = i + 1;
	}
	if (n > start)
		write_all(s + start, n - start);
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
