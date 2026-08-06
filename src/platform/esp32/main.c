/* esp32 boot sequence -- the analogue of src/platform/efi/main.c's
 * efi_main and src/platform/microvm/main.c's microvm_main, except that
 * this one is not an entry point. ESP-IDF has already brought up the
 * clocks, the heap, the console and FreeRTOS by the time app_main runs,
 * which is the whole reason this platform is small: microvm had to
 * write paging, an IDT, a LAPIC, a PMM and a uart to get this far.
 *
 * So lua-os is a FreeRTOS task rather than the only thing on the
 * machine. Two consequences worth stating rather than discovering:
 * kernel_run never returns, so app_main must not either; and the idle
 * path has to yield the core (idf_shim's WaitForEvent does), because
 * "nothing runnable" no longer means "nothing to run anywhere".
 *
 * There is no fw_cfg here, so unlike microvm there is no injected
 * payload: BOOT_PAYLOAD out of the embedded set is the only way code
 * starts. A test harness therefore selects its payload at build time,
 * not at boot.
 */

#include <stddef.h>
#include <stdio.h>

#include <esp_heap_caps.h>
#include <esp_system.h>

#include "cpu.h"
#include "esp32.h"
#include "fs.h"
#include "kernel.h"
#include "platform.h"

#define BOOT_PAYLOAD "/boot/esp32.lua"

void
app_main(void)
{
	console_init();

	/* Before anything measures a duration or logs a line. Costs 100ms
	 * of Stall, which idf_shim spends yielding rather than spinning.
	 */
	kernel_clock_init();

	kernel_log("lua-os on esp32");

	if (fs_init() != 0)
		platform_abort("fs_init failed");

	/* before kernel_init: it spawns the driver tasks by path, and
	 * those go through newlib's fopen rather than fs_open here.
	 */
	vfs_embed_register();

	if (kernel_init() != 0)
		platform_abort("kernel_init failed");

	if (kernel_spawn_file(BOOT_PAYLOAD) < 0)
		platform_abort("cannot spawn " BOOT_PAYLOAD);

	kernel_run();

	/* kernel_run returns only when every proc has died, which on a
	 * board with no other way in means there is nothing left to do.
	 * Say so rather than dropping off the end of the task.
	 */
	kernel_log("all procs exited");
	machine_halt();
}

/* ---- the one cpu ----
 *
 * The kernel runs on a single FreeRTOS task, so from kernel.c's side
 * this machine has one cpu whatever the chip has: an S3 carries two
 * xtensa cores and a C5 one RISC-V core beside a low-power one, and no
 * second core runs Lua. NCPU is 1 here, so lock.h compiles every lock
 * down to a compiler barrier and nothing below is ever contended.
 *
 * The same arrangement efi has, for a stronger reason: a second core
 * would mean running the scheduler outside the task IDF handed us,
 * beside a wifi driver and a FreeRTOS that decide their own affinity.
 */
static struct cpu thecpu = { .self = &thecpu, .idx = 0, .apicid = 0 };

struct cpu *
cpu_self(void)
{
	return &thecpu;
}

struct cpu *
cpu_at(unsigned i)
{
	return i == 0 ? &thecpu : 0;
}

unsigned
platform_ncpu(void)
{
	return 1;
}

/* one cpu, so there is never another to wake. */
void
platform_wake_cpu(unsigned i)
{
	(void)i;
}
