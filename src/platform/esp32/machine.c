/* the machine, for every esp32 this platform runs on.
 *
 * Nothing here is about the core. It is esp_timer, esp_heap_caps and
 * FreeRTOS, so it serves an xtensa S3 and a RISC-V C5 alike -- which is
 * the whole reason a second chip family cost no port: IDF brings the
 * toolchain, the FreeRTOS port and newlib, and src/platform/esp32 is
 * written against IDF rather than against a processor.
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

#include <sdkconfig.h>

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

/* the core this build is for, which the image knows and the file no
 * longer assumes. `ps` and the boot banner report it, and a board that
 * called itself xtensa while running RISC-V is the kind of wrong that
 * survives for years.
 */
const char *
platform_arch(void)
{
#if CONFIG_IDF_TARGET_ARCH_RISCV
	return "riscv32";
#else
	return "xtensa";
#endif
}

/* Internal SRAM only, deliberately. `avail` is what the lua heaps draw
 * on, and a proc's heap wants the memory the CPU caches best; PSRAM is
 * reported separately by whoever asks for it. Counting both here would
 * tell the scheduler it has 8MB of equally good memory, which is the
 * one thing that is not true on this board.
 */
void
platform_meminfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest)
{
	multi_heap_info_t info;

	heap_caps_get_info(&info, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
	if (total)
		*total = info.total_free_bytes + info.total_allocated_bytes;
	if (avail)
		*avail = info.total_free_bytes;
	if (largest)
		*largest = info.largest_free_block;
}

/* the pool the lua heap's chunks come from: PSRAM where the board has
 * it, and the same internal sram as above where it has not.
 *
 * This is the figure that matters on a T-Deck. The heaps are the bulk
 * of what the machine allocates and they are all in PSRAM, so a board
 * can be out of room for another proc while platform_meminfo still
 * reports 170KB free -- which is what made an out-of-memory look like
 * a per-proc cost that was never there.
 */
void
platform_chunkinfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest)
{
	multi_heap_info_t info;
	uint32_t caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;

#if CONFIG_SPIRAM
	if (heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0)
		caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
#endif
	heap_caps_get_info(&info, caps);
	if (total)
		*total = info.total_free_bytes + info.total_allocated_bytes;
	if (avail)
		*avail = info.total_free_bytes;
	if (largest)
		*largest = info.largest_free_block;
}

/* the C heap, for sys.stats.
 *
 * The other platforms count this in their own malloc; here the
 * allocator is IDF's, which keeps the same figures already. Every
 * capability, not just internal SRAM as above: what this answers is
 * how much C allocation the machine is holding, and a lua heap chunk
 * in PSRAM is as much of that as a port message in SRAM.
 *
 * peak is derived rather than tracked: IDF records the low-water mark
 * of free memory, so the most that was ever allocated is the pool
 * minus that. total_allocs it does not keep, and 0 says so.
 */
void
kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total)
{
	multi_heap_info_t info;

	heap_caps_get_info(&info, MALLOC_CAP_8BIT);
	if (live)
		*live = info.total_allocated_bytes;
	if (peak)
		*peak = info.total_free_bytes + info.total_allocated_bytes -
		    info.minimum_free_bytes;
	if (blocks)
		*blocks = info.allocated_blocks;
	if (total)
		*total = 0;
}

/* the lua heap's chunks, from PSRAM where the board has it.
 *
 * Asked for explicitly rather than inferred from the request size.
 * CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL serves anything at or below its
 * threshold (4096 by default) from internal sram, so a heap whose
 * chunks are smaller than that never sees PSRAM however much is
 * fitted. Naming the memory we want makes the chunk size a tuning
 * decision instead of a placement one.
 *
 * The fallback is for the board with no PSRAM, where
 * heap_caps_malloc(MALLOC_CAP_SPIRAM) has nothing to give whatever is
 * asked -- and it is taken only where the board has none at all, which
 * is decided once and not per call.
 *
 * A board WITH PSRAM must be refused instead, because the fallback on
 * that board is not an error path but a disaster. luaheap answers a
 * refusal by returning its cached large blocks and its empty chunks and
 * asking again (see chunk_new): the whole reclaim path is driven by the
 * chunk source saying no. Falling back to internal sram means it never
 * says no, so nothing is ever reclaimed, and the machine quietly spends
 * the sram that everything else needs -- ports, message payloads, DMA.
 * Measured: eight terminals took PSRAM to its ceiling and then took
 * internal sram from 175KB to 12KB, killing a proc and leaving no room
 * to draw. Refused, the heap gives back what it is holding and the
 * board stays alive.
 */
void *
platform_chunk_alloc(size_t n)
{
#if CONFIG_SPIRAM
	/* asked once: heap_caps_get_info walks the pool, and this is the
	 * allocator's hot path. A board's PSRAM does not come and go.
	 */
	static int havepsram = -1;

	if (havepsram < 0)
		havepsram = heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0;
	if (havepsram)
		return heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#endif
	return heap_caps_malloc(n, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
}

void
platform_chunk_free(void *p, size_t n)
{
	(void)n;
	heap_caps_free(p);
}
