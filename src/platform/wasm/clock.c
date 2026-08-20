/* the machine's tick and its idle sleep, in the shape kernel.c was
 * written against. One event exists -- the periodic scheduler tick --
 * so an event need only remember which tick its owner last saw.
 */

#include <stdlib.h>

#include "efi.h"
#include "host.h"
#include "platform.h"
#include "wasm.h"

static unsigned long long period_us = 10000;

static unsigned long long
now_us(void)
{
	return host_now_ns() / 1000ULL;
}

static unsigned long long
tick_now(void)
{
	unsigned long long us = now_us();

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

/* idle until the next tick or until something is typed. A host that
 * cannot block returns at once and the machine spins, which costs cpu
 * and stays correct.
 */
static EFI_STATUS
shim_wait_for_event(UINTN n, EFI_EVENT *evs, UINTN *index)
{
	(void)n;
	(void)evs;

	unsigned long long now = now_us();
	unsigned long long next = (now / period_us + 1) * period_us;
	int ms = (int)((next - now + 999) / 1000);

	/* a screen sleeps with the machine: an idle guest that left it
	 * dirty must still show what it drew.
	 */
	fb_flush();

	host_wait(ms < 1 ? 1 : ms);
	if (index)
		*index = 0;
	return EFI_SUCCESS;
}

void
wasm_stall_us(unsigned long us)
{
	unsigned long long end = now_us() + us;

	while (now_us() < end)
		host_wait((int)((end - now_us() + 999) / 1000));
}

static void
shim_stall(UINTN us)
{
	wasm_stall_us((unsigned long)us);
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
