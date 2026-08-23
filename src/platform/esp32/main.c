/* esp32 boot sequence -- the analogue of src/platform/efi/main.c's
 * efi_main and src/platform/microvm/main.c's microvm_main, except that
 * this one is not an entry point. ESP-IDF has already brought up the
 * clocks, the heap, the console and FreeRTOS by the time app_main runs,
 * which is the whole reason this platform is small: microvm had to
 * write paging, an IDT, a LAPIC, a PMM and a uart to get this far.
 *
 * So lua-os is a FreeRTOS task rather than the only thing on the
 * machine, and it picks which core that task runs on. The idle path
 * has to yield the core (idf_shim's WaitForEvent does), because
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
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/idf_additions.h>

#include "cpu.h"
#include "esp32.h"
#include "fs.h"
#include "kernel.h"
#include "platform.h"

#define BOOT_PAYLOAD "/boot/esp32.lua"

/* the boot cpu, and cpus[0]: an index here is a core id. */
#define KERNEL_CORE	0
#define KERNEL_STACK	CONFIG_ESP_MAIN_TASK_STACK_SIZE
#define AP_STACK	KERNEL_STACK

/* One FreeRTOS task per cpu, pinned; a cpu index is its core id. */
static struct cpu cpus[NCPU];
static TaskHandle_t aptask[NCPU];
static unsigned ncpu = 1;

static void smp_start(void);

static void
smp_init(void)
{
	for (unsigned i = 0; i < NCPU; i++) {
		cpus[i].self = &cpus[i];
		cpus[i].idx = i;
		cpus[i].apicid = i;
	}
}

static void
kernel_task(void *arg)
{
	(void)arg;

	if (kernel_spawn_file(BOOT_PAYLOAD) < 0)
		platform_abort("cannot spawn " BOOT_PAYLOAD);

	smp_start();
	kernel_run();

	/* only when every proc has died, and this board has no other
	 * way in, so there is nothing left to do.
	 */
	kernel_say("all procs exited");
	machine_halt();
}

void
app_main(void)
{
	console_init();

	/* Before anything measures a duration or logs a line. Costs 100ms
	 * of Stall, which idf_shim spends yielding rather than spinning.
	 */
	kernel_clock_init();

	kernel_say("lua-os on esp32");

	if (fs_init() != 0)
		platform_abort("fs_init failed");

	/* before kernel_init: it spawns the driver tasks by path, and
	 * those go through newlib's fopen rather than fs_open here.
	 */
	vfs_embed_register();

	smp_init();

	if (kernel_init() != 0)
		platform_abort("kernel_init failed");

	/* app_main may now return: IDF deletes only the task it was on. */
	if (xTaskCreatePinnedToCore(kernel_task, "luaos", KERNEL_STACK, NULL,
	    5, NULL, KERNEL_CORE) != pdPASS)
		platform_abort("cannot start the kernel task");
}

/* Clamped: IDF calls in from its own tasks, on whichever core it likes. */
struct cpu *
cpu_self(void)
{
	unsigned i = esp_cpu_get_core_id();

	return &cpus[i < ncpu ? i : 0];
}

struct cpu *
cpu_at(unsigned i)
{
	return i < ncpu ? &cpus[i] : 0;
}

unsigned
platform_ncpu(void)
{
	return ncpu;
}

/* A wake between an empty queue and the take is not lost: the
 * notification is already pending. Cpu 0 sleeps in the shim instead.
 */
void
platform_wake_cpu(unsigned i)
{
	if (i < ncpu && aptask[i])
		xTaskNotifyGive(aptask[i]);
}

void
platform_cpu_idle(void)
{
	ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
}

/* the counted notification is the window microvm masks interrupts for */
void
platform_intr_off(void)
{
}

void
platform_intr_on(void)
{
}

static void
ap_task(void *arg)
{
	(void)arg;
	kernel_run_ap();
	vTaskDelete(NULL);
}

/* After the first proc exists, and ncpu before the task: an ap asks
 * cpu_self at once, and one started on an idle machine parks for good.
 */
static void
smp_start(void)
{
	for (unsigned i = 1; i < NCPU; i++) {
		ncpu = i + 1;
		/* internal sram, not PSRAM: a task on a PSRAM stack may
		 * not be alive while a flash write turns the cache off.
		 */
		if (xTaskCreatePinnedToCore(ap_task, "luaos-ap",
		    AP_STACK, NULL, 5, &aptask[i], (int)i) != pdPASS) {
			ncpu = i;
			kernel_say("smp: a cpu would not start");
			return;
		}
	}
	if (ncpu > 1)
		kernel_say("smp: a second cpu");
}
