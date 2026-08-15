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
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include <esp_vfs.h>

#include <sdkconfig.h>
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
#include <driver/usb_serial_jtag.h>
#include <driver/usb_serial_jtag_vfs.h>
#endif

#include "esp32.h"
#include "platform.h"

#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG

/* stdout and stderr, on the same path console_write uses.
 *
 * The USB console only. There, console_write reaches the
 * usb_serial_jtag driver directly and never goes through stdio, so
 * without this everything printed to a standard stream is lost. On a
 * uart console stdout already reaches the console and write_all is an
 * fwrite to it, so redirecting would make console_write call itself.
 *
 * IDF's own console VFS writes one character at a time, and when the
 * port is not being drained it tries one non-blocking write, then one
 * blocking write with a timeout, and then discards until a later write
 * succeeds (usbjtag_tx_char_via_driver). Output is dropped exactly when
 * something is going wrong, which is when it is wanted: a program
 * reporting why it failed through io.stderr said nothing at all.
 *
 * So the standard streams are reopened on a vfs of our own whose write
 * reaches console_write, which chunks and retries. printf, io.write,
 * io.stderr and ESP_LOG all arrive by it.
 */
static ssize_t
con_vfs_write(int fd, const void *data, size_t size)
{
	(void)fd;
	console_write(data, size);
	return (ssize_t)size;
}

static int
con_vfs_open(const char *path, int flags, int mode)
{
	(void)path;
	(void)flags;
	(void)mode;
	return 0;
}

static int
con_vfs_close(int fd)
{
	(void)fd;
	return 0;
}

static int
con_vfs_fstat(int fd, struct stat *st)
{
	(void)fd;
	memset(st, 0, sizeof *st);
	st->st_mode = S_IFCHR;
	return 0;
}

static void
console_stdio_redirect(void)
{
	static const esp_vfs_t vfs = {
		.flags = ESP_VFS_FLAG_DEFAULT,
		.write = con_vfs_write,
		.open = con_vfs_open,
		.close = con_vfs_close,
		.fstat = con_vfs_fstat,
	};

	if (esp_vfs_register("/dev/luaos", &vfs, NULL) != ESP_OK)
		return;
	if (freopen("/dev/luaos/con", "w", stdout))
		setvbuf(stdout, NULL, _IONBF, 0);
	if (freopen("/dev/luaos/con", "w", stderr))
		setvbuf(stderr, NULL, _IONBF, 0);
}

#endif

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
	/* Receive is the asymmetric one. This is USB, not a 115200 line:
	 * the host delivers as fast as it is asked to, while a receiver
	 * stops reading for a flash write measured at 19ms. What arrives
	 * meanwhile has to fit, or the sender retransmits -- 1.9x the
	 * bytes for a 24KB file at 4096.
	 */
	cfg.rx_buffer_size = 16384;

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

	/* after stdin is set up: this moves only the output streams, and
	 * reading still goes through the driver's own vfs.
	 *
	 * Only where the console is the USB link. There, console_write
	 * goes straight to the usb_serial_jtag driver and bypasses stdio,
	 * so anything printed through stdout would be lost without this.
	 *
	 * On a uart console stdout already reaches the console, and
	 * write_all below is an fwrite to it -- so redirecting stdout
	 * into this file would make console_write call itself. The first
	 * line the kernel printed would recurse until the stack went,
	 * which reads as a board that boots as far as IDF's own logs and
	 * then says nothing at all.
	 */
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	console_stdio_redirect();
#endif
}

/* Raw mode: pass bytes through untouched. The translation below
 * corrupts any binary stream carrying 0x0a. Headers survive it, being
 * printable, so the failure reads as a transfer that stalls after the
 * file is created rather than as line endings.
 */
static int rawmode;

/* Write straight at the driver, not through stdio: IDF's vfs path
 * discards every byte after one blocking write times out, which is
 * right for an absent host and corrupting for a slow one. Loop until
 * the driver has taken it all, then give up -- a console with nobody
 * on the other end must not wedge the machine.
 */
static void
write_all(const char *s, size_t n)
{
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	/* Sticky: what it remembers is whether anything reads this port,
	 * which outlives any one write. Only the kernel task writes the
	 * console, so no lock.
	 */
	static bool detached = false;
	size_t off = 0;
	int idle = 0;

	/* In chunks, because usb_serial_jtag_write_bytes takes at most a
	 * buffer's worth per call and answers 0 for more -- and zmodem
	 * hands over every pending subpacket at once, well past that.
	 *
	 * A zero is "no room right now", not "nobody is listening", so it
	 * is retried -- briefly. This blocks inside a C call, where no
	 * quantum interrupts it and no other proc runs: an unread console
	 * would otherwise set the speed of everything on the board.
	 *
	 * Two different conditions have to be cheap. Nothing attached at
	 * all is what IDF's own VFS write asks before it touches the
	 * driver, so ask it too. Attached with nobody reading -- a cable
	 * in a PC, no terminal open -- still sends SOF, so that answers
	 * yes and the buffer fills anyway; `detached` is for that one.
	 */
	if (!usb_serial_jtag_is_connected())
		return;

	while (off < n) {
		size_t want = n - off;
		int w;

		if (want > 512)
			want = 512;

		/* a detached console is probed with no wait, so a write to
		 * one costs a call and not a sleep.
		 */
		w = usb_serial_jtag_write_bytes(s + off, want,
		    detached ? 0 : pdMS_TO_TICKS(10));
		if (w > 0) {
			off += (size_t)w;
			idle = 0;
			detached = false;
		} else if (detached) {
			return;
		} else if (++idle > 5) {
			detached = true;	/* ~50ms, nobody reading */
			return;
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

/* What has arrived and nobody has asked for yet. The kernel takes input
 * a byte at a time, and on this console a byte costs a driver call. A
 * file arriving at USB speed outruns that, and what does not fit in the
 * driver's ring meanwhile is dropped -- which reads as a transfer that
 * resends, not as a slow console.
 */
static unsigned char rxbuf[1024];
static size_t rxlen, rxpos;

static void
fill(void)
{
	int n;

	if (rxpos < rxlen)
		return;
	rxlen = rxpos = 0;
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	n = usb_serial_jtag_read_bytes(rxbuf, sizeof rxbuf, 0);
#else
	n = (int)read(STDIN_FILENO, rxbuf, sizeof rxbuf);
#endif
	if (n > 0)
		rxlen = (size_t)n;
}

int
console_peek(void)
{
	fill();
	return rxpos < rxlen;
}

int
console_getchar(void)
{
	fill();
	if (rxpos < rxlen)
		return rxbuf[rxpos++];
	return -1;
}

/* IDF owns this board's watchdog: the task WDT, set in sdkconfig. */
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
