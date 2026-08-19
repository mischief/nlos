/* the machine's tick, its idle sleep and its keyboard: a monotonic
 * clock and poll(2), reached through the vtable in efi.h because that
 * is the shape kernel.c was written against. It creates exactly one
 * event -- the periodic scheduler tick -- so an "event" need only
 * remember which tick its owner last saw.
 */

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "efi.h"
#include "hosted.h"
#include "platform.h"

/* the tick the scheduler asked for. Set by SetTimer, read by CheckEvent
 * and WaitForEvent, so the idle sleep is exactly as long as the next
 * deadline rather than a fixed guess.
 */
static unsigned long long period_us = 10000;

static unsigned long long
tick_now(void)
{
	unsigned long long us = hosted_now_us();

	return period_us ? us / period_us : us;
}

static EFI_STATUS
shim_create_event(unsigned type, UINTN tpl, void *notify, void *ctx,
    EFI_EVENT *out)
{
	(void)type;
	(void)tpl;
	(void)notify;
	(void)ctx;

	unsigned long long *seen = malloc(sizeof *seen);

	if (!seen)
		return EFI_NOT_READY;
	*seen = tick_now();
	*out = seen;
	return EFI_SUCCESS;
}

static EFI_STATUS
shim_set_timer(EFI_EVENT ev, EFI_TIMER_DELAY type,
    unsigned long long triggertime_100ns)
{
	(void)ev;
	(void)type;
	period_us = triggertime_100ns / 10;
	if (period_us == 0)
		period_us = 1;
	return EFI_SUCCESS;
}

static EFI_STATUS
shim_check_event(EFI_EVENT ev)
{
	unsigned long long *seen = ev;
	unsigned long long now = tick_now();

	if (now != *seen) {
		*seen = now;
		return EFI_SUCCESS;
	}
	return EFI_NOT_READY;
}

/* idle until the next tick, or until something is typed. The console is
 * the only device here, so its descriptor is the whole wait set and the
 * events passed in say nothing this does not already know.
 */
static EFI_STATUS
shim_wait_for_event(UINTN n, EFI_EVENT *evs, UINTN *index)
{
	(void)n;
	(void)evs;

	unsigned long long now = hosted_now_us();
	unsigned long long next = (now / period_us + 1) * period_us;
	int ms = (int)((next - now + 999) / 1000);

	/* the console, plus whatever socket has an operation outstanding.
	 * Without the sockets here the machine still works and answers a
	 * tick late every time, which is a wait of milliseconds on every
	 * packet.
	 */
	struct pollfd pfd[NET_POLLMAX + 1];
	int nfd = net_pollfds(pfd + 1, NET_POLLMAX) + 1;

	pfd[0].fd = console_infd();
	pfd[0].events = POLLIN;
	pfd[0].revents = 0;

	/* a window sleeps with the machine, so its events and its repaint
	 * happen here as well as in the device reads: an idle guest whose
	 * screen was left dirty must still show it.
	 */
	fb_pump();
	fb_flush();

	if (ms < 1)
		ms = 1;
	while (poll(pfd, (nfds_t)nfd, ms) < 0 && errno == EINTR)
		;
	if (index)
		*index = 0;
	return EFI_SUCCESS;
}

/* a real sleep, so a process that is stalling costs the host nothing.
 * Restarted on a signal: the caller asked for a duration.
 */
void
hosted_stall_us(unsigned long us)
{
	struct timespec ts = {
		.tv_sec = (time_t)(us / 1000000),
		.tv_nsec = (long)(us % 1000000) * 1000,
	};

	while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
		;
}

static void
shim_stall(UINTN us)
{
	hosted_stall_us((unsigned long)us);
}

static EFI_STATUS
shim_read_key(EFI_SIMPLE_TEXT_INPUT_PROTOCOL *self, EFI_INPUT_KEY *key)
{
	(void)self;

	int c = console_getchar();

	if (c < 0)
		return EFI_NOT_READY;
	key->ScanCode = 0;
	key->UnicodeChar = (unsigned short)c;
	return EFI_SUCCESS;
}

static EFI_SIMPLE_TEXT_INPUT_PROTOCOL conin_impl = {
	.ReadKeyStroke = shim_read_key,
	.WaitForKey = (EFI_EVENT)1,	/* never signaled, never waited on alone */
};

static EFI_SYSTEM_TABLE st_impl = {
	.ConIn = &conin_impl,
};

static EFI_BOOT_SERVICES bs_impl = {
	.CreateEvent = shim_create_event,
	.SetTimer = shim_set_timer,
	.CheckEvent = shim_check_event,
	.WaitForEvent = shim_wait_for_event,
	.Stall = shim_stall,
};

EFI_BOOT_SERVICES *BS = &bs_impl;
EFI_SYSTEM_TABLE *ST = &st_impl;
