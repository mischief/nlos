/* microvm boot sequence -- the bare-metal analogue of
 * src/platform/efi/main.c's efi_main, called from boot.S's
 * long_mode_entry once paging/long mode/GDT are live.
 *
 * no real mount yet (see fs.c): the boot payload itself still comes in
 * over fw_cfg, the same mechanism src/platform/efi/main.c uses for the
 * test harness -- reused here as the ONLY way to run code, not just
 * the test path, since there is no virtio-9p root yet
 * (docs/microvm-plan.md). fs_init() below does succeed, though: the
 * embed half of fs.c's embed -> namespace lookup always exists, which
 * is what lets the boot payload's own require()s (los.thread, and
 * whatever the driver tasks need) resolve.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "fs.h"
#include "kernel.h"
#include "microvm.h"
#include "platform.h"

int	fwcfg_load(const char *name, char **buf, size_t *len);

/* 16MB-128MB: comfortably above our own image (linked at 1MB, well
 * under 16MB even with Lua statically linked in -- see meson.build)
 * and below the smallest -m this platform is tested with. hardcoded
 * rather than parsed from hvm_start_info's memory map, which is
 * future work (docs/microvm-plan.md).
 */
#define HEAP_BASE 0x1000000UL
#define HEAP_LEN  0x7000000UL

void
microvm_main(unsigned long start_info)
{
	(void)start_info;	/* hvm_start_info memmap: not parsed yet */

	uart_init();
	tsc_calibrate();
	pmm_init(HEAP_BASE, HEAP_LEN);
	idt_init();
	lapic_init();

	kernel_clock_init();

	if (fs_init() != 0)
		kernel_log("boot: fs_init FAILED (unexpected: embed has no failure mode)");

	char cbuf[96];

	kernel_log("boot: lua-os starting (microvm)");
	snprintf(cbuf, sizeof cbuf,
	    "clock: %llu cycles/ms (cpuid leaf 0x16, not wall-clock measured)",
	    kernel_cyc_per_ms());
	kernel_log(cbuf);

	{
		unsigned long long total = 0, avail = 0;

		platform_meminfo(&total, &avail);
		snprintf(cbuf, sizeof cbuf,
		    "mem: %lluK total, %lluK available",
		    total / 1024, avail / 1024);
		kernel_log(cbuf);
	}

	if (kernel_init() != 0) {
		kernel_log("boot: kernel_init FAILED");
		machine_reset();
	}

	char *testbuf;
	size_t testlen;

	if (fwcfg_load("opt/org.luaos.test", &testbuf, &testlen) == 0) {
		kernel_log("boot: running fw_cfg boot payload");
		if (kernel_spawn_buffer(testbuf, testlen) < 0) {
			kernel_log("boot: FAILED to spawn boot payload");
			machine_reset();
		}
		free(testbuf);
	} else {
		kernel_log("boot: no fw_cfg payload and no filesystem -- nothing to run");
		machine_reset();
	}

	kernel_run();

	kernel_log("boot: halted (every proc exited)");
	machine_reset();
}
