/* the console is the process's terminal, and this file is the only
 * thing that touches its descriptors. Lua's output path is
 * fwrite(..., stdout), and liolib builds io.stdout/stderr/stdin from
 * the same three globals, so console_init replaces all three: no FILE
 * the guest can name reaches fd 0, 1 or 2.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "hosted.h"
#include "platform.h"

/* the terminal, taken at startup and kept here. Duplicated out of 0/1
 * so that a later dup2 onto the standard descriptors cannot redirect
 * the console out from under the kernel.
 */
static int infd = -1, outfd = -1;

static int rawmode;		/* caller asked for bytes unrewritten */
static int istty;		/* the terminal is ours to put in raw mode */
static struct termios saved;

void
console_setraw(int on)
{
	rawmode = on;
}

int
console_infd(void)
{
	return infd;
}

/* both undone on the way out: dup shares the open file description, so
 * a terminal left non-blocking or raw is the shell's problem next.
 */
static void
console_restore(void)
{
	if (istty)
		tcsetattr(infd, TCSANOW, &saved);
	fcntl(infd, F_SETFL, fcntl(infd, F_GETFL, 0) & ~O_NONBLOCK);
}

/* write everything, or lose it: a short write on a pipe whose reader is
 * slow is normal, and a console that dropped the tail of a line would
 * be a diagnostic that lies.
 */
static void
writeall(const char *s, size_t n)
{
	while (n > 0) {
		ssize_t w = write(outfd, s, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return;
		}
		s += w;
		n -= w;
	}
}

/* bare \n becomes \r\n on a raw terminal, which no longer moves the
 * carriage for us. Off when the console is a pipe, so a captured log is
 * plain text, and off in rawmode, which is a program moving bytes.
 */
void
console_write(const char *s, size_t n)
{
	size_t start = 0;

	if (rawmode || !istty) {
		writeall(s, n);
		return;
	}
	for (size_t i = 0; i < n; i++) {
		if (s[i] != '\n')
			continue;
		if (i > start)
			writeall(s + start, i - start);
		writeall("\r\n", 2);
		start = i + 1;
	}
	if (n > start)
		writeall(s + start, n - start);
}

/* the next byte typed, or -1. The descriptor is non-blocking: a read
 * that waited would stop every proc on the machine, since this is the
 * kernel's own thread of control and not a task.
 */
int
console_getchar(void)
{
	unsigned char c;
	ssize_t r;

	do {
		r = read(infd, &c, 1);
	} while (r < 0 && errno == EINTR);
	return r == 1 ? c : -1;
}

/* the backing for the three replaced streams. Lua writes through
 * cookies rather than to a descriptor, so io.write, print and a
 * kernel_log line all arrive at console_write in the order they were
 * called, with nothing buffered behind them.
 */
static ssize_t
cookie_write(void *ck, const char *buf, size_t n)
{
	(void)ck;
	console_write(buf, n);
	return (ssize_t)n;
}

static ssize_t
cookie_read(void *ck, char *buf, size_t n)
{
	(void)ck;
	if (n == 0)
		return 0;

	int c = console_getchar();

	if (c < 0)
		return 0;		/* nothing typed reads as end of file */
	buf[0] = (char)c;
	return 1;
}

static FILE *
cookie_stream(const char *mode, int reader)
{
	cookie_io_functions_t fns = {
		.read = reader ? cookie_read : NULL,
		.write = reader ? NULL : cookie_write,
	};
	FILE *f = fopencookie(NULL, mode, fns);

	if (f)
		setvbuf(f, NULL, _IONBF, 0);
	return f;
}

void
console_init(void)
{
	struct termios raw;

	infd = dup(0);
	outfd = dup(1);
	if (infd < 0 || outfd < 0)
		platform_abort("console: cannot duplicate the terminal");

	/* console_getchar polls and must never wait, whether the input is
	 * a terminal or a pipe.
	 */
	fcntl(infd, F_SETFL, fcntl(infd, F_GETFL, 0) | O_NONBLOCK);
	atexit(console_restore);

	if (tcgetattr(infd, &saved) == 0) {
		istty = 1;
		raw = saved;
		cfmakeraw(&raw);
		raw.c_cc[VMIN] = 0;
		raw.c_cc[VTIME] = 0;
		tcsetattr(infd, TCSANOW, &raw);
	}

	FILE *out = cookie_stream("w", 0);
	FILE *in = cookie_stream("r", 1);

	if (!out || !in)
		platform_abort("console: cannot wrap the standard streams");

	/* glibc's three globals are ordinary pointers, and replacing them
	 * is what puts the console out of the guest's reach: every FILE
	 * lua can name is now one of these.
	 */
	stdout = out;
	stderr = out;
	stdin = in;
}

/* nothing here to reset the machine, and a process that stopped running
 * the reactor is a bug to debug rather than one to reboot away.
 */
void
platform_watchdog(unsigned secs)
{
	(void)secs;
}

_Noreturn void
platform_abort(const char *why)
{
	if (outfd >= 0) {
		console_write("PANIC: ", 7);
		if (why)
			console_write(why, strlen(why));
		console_write("\n", 1);
	}
	console_restore();
	_exit(1);
}

/* the wire, which this platform does not have: one terminal and no
 * second serial line. platform_have_wire answers no, so nothing above
 * calls these -- they exist because kernel.c takes their addresses.
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
