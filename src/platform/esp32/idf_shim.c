/* backs the EFI Boot Services / System Table slice kernel.c calls (see
 * efi.h beside this file) with esp_timer and a FreeRTOS delay.
 *
 * Same shape as src/platform/microvm/efi_shim.c and for the same
 * reason: kernel_run creates exactly one event, the periodic scheduler
 * tick, so an "event" need only remember the tick count its owner last
 * observed. Nothing here has to tell two events apart.
 *
 * What differs from microvm is WaitForEvent. There the idle path halts
 * the cpu until an interrupt; here it hands the core back to FreeRTOS,
 * which is the same bargain in a different currency -- lua-os is one
 * task among several, and an idle kernel that spun would starve the
 * IDF timer service and whatever else shares this core.
 */

#include <stdlib.h>

#include <esp_timer.h>
#include <esp_rom_sys.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "efi.h"
#include "esp32.h"
#include "kbd.h"
#include "touch.h"
#include "platform.h"

/* the tick the scheduler asked for, in microseconds. Set by SetTimer
 * and read by both CheckEvent and WaitForEvent, so the idle sleep is
 * always exactly as long as the next deadline and never a fixed guess.
 */
static unsigned long long period_us = 10000;

static unsigned long long
now_us(void)
{
	return (unsigned long long)esp_timer_get_time();
}

/* which tick we are in. CheckEvent reports "a new one has begun since
 * you last asked", which is all kernel_run wants from it.
 */
static unsigned long long
tick_now(void)
{
	return period_us ? now_us() / period_us : now_us();
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

/* 100ns units in, microseconds out -- the EFI unit, kept because
 * kernel.c speaks it and this file exists to spare kernel.c the
 * knowledge that it is talking to FreeRTOS.
 */
static EFI_STATUS
shim_set_timer(EFI_EVENT ev, EFI_TIMER_DELAY type,
    unsigned long long triggertime_100ns)
{
	(void)ev;
	(void)type;
	period_us = triggertime_100ns / 10;
	if (period_us == 0)
		period_us = 1000;
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

/* Sleep until the current tick ends, or until a key shows up -- whoever
 * is first. The console is polled rather than waited on because the IDF
 * console VFS has no "wake me on a byte" that composes with a timeout,
 * and a tick is 10ms, so a keystroke waits 5ms on average. That is
 * under the threshold where typing feels laggy, and it keeps this
 * function free of a second wakeup mechanism to get wrong.
 */
static EFI_STATUS
shim_wait_for_event(UINTN n, EFI_EVENT *evs, UINTN *index)
{
	(void)evs;

	unsigned long long start = tick_now();
	TickType_t slice = pdMS_TO_TICKS(1);

	if (slice == 0)
		slice = 1;

	for (;;) {
		if (tick_now() != start)
			break;
		if (console_peek())
			break;
		/* the matrix keyboard, which cannot interrupt: scanned
		 * here so nothing above has to poll, and a keypress ends
		 * the sleep exactly as a serial byte does.
		 */
		if (esp_kbd_poll())
			break;

		/* the touch panel, scanned here for the same reason: a
		 * finger arriving ends the sleep as a keystroke does, so a
		 * pointer is as responsive as the keyboard rather than
		 * waiting out the tick.
		 */
		if (esp_touch_poll())
			break;
		vTaskDelay(slice);
	}
	if (index)
		*index = 0;
	(void)n;
	return EFI_SUCCESS;
}

/* Short stalls busy-wait in ROM (a FreeRTOS delay cannot resolve below
 * one tick, and kernel_clock_init calibrates with 100ms of this, where
 * being descheduled would inflate the measured rate). Long ones yield,
 * because burning 100ms of a shared core is the thing this platform
 * cannot afford.
 */
static void
shim_stall(UINTN microseconds)
{
	if (microseconds < 1000) {
		esp_rom_delay_us(microseconds);
		return;
	}

	unsigned long long deadline = now_us() + microseconds;

	while (now_us() < deadline) {
		unsigned long long left = deadline - now_us();

		if (left > 2000)
			vTaskDelay(pdMS_TO_TICKS(1));
		else
			esp_rom_delay_us(left);
	}
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

static EFI_SIMPLE_TEXT_INPUT_PROTOCOL conin = {
	.ReadKeyStroke = shim_read_key,
	.WaitForKey = 0,
};

static EFI_BOOT_SERVICES bs = {
	.CreateEvent = shim_create_event,
	.SetTimer = shim_set_timer,
	.CheckEvent = shim_check_event,
	.WaitForEvent = shim_wait_for_event,
	.Stall = shim_stall,
};

static EFI_SYSTEM_TABLE st = {
	.ConIn = &conin,
};

EFI_BOOT_SERVICES *BS = &bs;
EFI_SYSTEM_TABLE *ST = &st;
