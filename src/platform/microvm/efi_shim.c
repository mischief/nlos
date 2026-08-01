/* backs the small EFI Boot Services / System Table slice kernel.c
 * calls (see efi.h in this directory) with the LAPIC timer tick and
 * TSC-based stall from lapic.c/tsc.c. There is exactly one event
 * kernel_run ever creates and checks -- the periodic scheduler tick --
 * so CreateEvent/SetTimer/CheckEvent don't need to distinguish between
 * events; each "event" is just a snapshot of the last tick count its
 * owner observed.
 */

#include <stdlib.h>

#include "efi.h"

void	lapic_timer_arm_periodic(unsigned long long period_100ns);
unsigned long long lapic_ticks(void);
void	platform_stall_us(unsigned long us);

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
	*seen = lapic_ticks();
	*out = seen;
	return EFI_SUCCESS;
}

static EFI_STATUS
shim_set_timer(EFI_EVENT ev, EFI_TIMER_DELAY type,
    unsigned long long triggertime_100ns)
{
	(void)ev;
	(void)type;
	lapic_timer_arm_periodic(triggertime_100ns);
	return EFI_SUCCESS;
}

static EFI_STATUS
shim_check_event(EFI_EVENT ev)
{
	unsigned long long *seen = ev;
	unsigned long long now = lapic_ticks();

	if (now != *seen) {
		*seen = now;
		return EFI_SUCCESS;
	}
	return EFI_NOT_READY;
}

static EFI_STATUS
shim_wait_for_event(UINTN n, EFI_EVENT *evs, UINTN *index)
{
	(void)n;
	(void)evs;

	unsigned long long before = lapic_ticks();

	while (lapic_ticks() == before)
		__asm__ volatile ("hlt");
	if (index)
		*index = 0;
	return EFI_SUCCESS;
}

static void
shim_stall(UINTN us)
{
	platform_stall_us(us);
}

static EFI_STATUS
shim_read_key(EFI_SIMPLE_TEXT_INPUT_PROTOCOL *self, EFI_INPUT_KEY *key)
{
	(void)self;
	(void)key;
	return EFI_NOT_READY;	/* no keyboard on microvm */
}

static EFI_SIMPLE_TEXT_INPUT_PROTOCOL conin_impl = {
	.ReadKeyStroke = shim_read_key,
	.WaitForKey = (EFI_EVENT)1,	/* never signaled, never waited on individually */
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
