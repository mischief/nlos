/* xtensa machine bits, for the esp32 platform.
 *
 * The counter is esp_timer's and not the core's CCOUNT, which matters
 * enough to say why: platform_ticks must be free-running and 64-bit,
 * and CCOUNT is 32 bits at 240MHz -- it wraps every 17.9 seconds, which
 * every duration in the kernel would then read wrong once a minute.
 * esp_timer_get_time is a 64-bit microsecond count off the same
 * hardware IDF uses for its own timers, so the "the counter never
 * wraps" property the rest of the tree relies on holds here as it does
 * on the other three arches. The consequence is that a tick IS a
 * microsecond, so kernel_clock_init calibrates to 1000 per ms.
 *
 * There is no setjmp.S here. Xtensa has register windows, so setjmp
 * must spill them rather than save a callee-saved set, and newlib's
 * comes with the toolchain already correct.
 */

#include <esp_timer.h>
#include <esp_system.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "platform.h"

unsigned long long
platform_ticks(void)
{
	return (unsigned long long)esp_timer_get_time();
}

/* Halting means halting this machine, and on a board whose only console
 * is the USB link that is indistinguishable from a hang. Park the task
 * instead of spinning: FreeRTOS keeps running, so the log that got us
 * here still drains and the port stays open.
 */
_Noreturn void
machine_halt(void)
{
	for (;;)
		vTaskDelay(portMAX_DELAY);
}

const char *
platform_arch(void)
{
	return "xtensa";
}

/* Internal SRAM only, deliberately. `avail` is what the lua heaps draw
 * on, and a proc's heap wants the memory the CPU caches best; PSRAM is
 * reported separately by whoever asks for it. Counting both here would
 * tell the scheduler it has 8MB of equally good memory, which is the
 * one thing that is not true on this board.
 */
void
platform_meminfo(unsigned long long *total, unsigned long long *avail)
{
	multi_heap_info_t info;

	heap_caps_get_info(&info, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
	if (total)
		*total = info.total_free_bytes + info.total_allocated_bytes;
	if (avail)
		*avail = info.total_free_bytes;
}
