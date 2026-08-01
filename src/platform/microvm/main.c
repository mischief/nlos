/* microvm boot sequence -- the bare-metal analogue of
 * src/platform/efi/main.c's efi_main, called from boot.S's
 * long_mode_entry once paging/long mode/GDT are live.
 *
 * The boot payload comes in over fw_cfg, the same mechanism
 * src/platform/efi/main.c uses for its test harness, but here it is the
 * only way to start code rather than just the test path: there is no
 * disk and no /init.lua to fall back on. What a payload then mounts is
 * its own business -- virtio-9p is available to it (see fs.c) -- but
 * something has to run first to do the mounting.
 *
 * fs_init() cannot fail: the embedded set it serves is built in.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "fs.h"
#include "kernel.h"
#include "microvm.h"
#include "platform.h"
#include "pvh.h"

int	fwcfg_load(const char *name, char **buf, size_t *len);

extern char __image_end[];	/* microvm.ld */

/* what to fall back on when the map cannot be read: 16MB-128MB, above
 * our own image (linked at 1MB, well under 16MB even with Lua linked
 * in) and inside the smallest -m worth booting. Only reachable on a
 * loader that is not qemu's microvm, since that one always supplies a
 * version 1 start_info.
 */
#define FALLBACK_BASE 0x1000000UL
#define FALLBACK_LEN  0x7000000UL

/* the first megabyte is legacy holes -- real mode IVT, EBDA, VGA,
 * option ROMs -- and qemu reports parts of it as RAM anyway. Nothing
 * here needs it, so skip it rather than special-case what is safe.
 */
#define LOW_LIMIT 0x100000UL

/* boot.S identity-maps exactly the low 4GB (2MB pages, four PDs), so
 * that is the ceiling on what may be handed to the allocator no matter
 * what the machine has. pmm_add writes a block header at the base of
 * every range it is given, which on an unmapped address faults before
 * uart_init's output has even been flushed -- a -m 6144 guest died
 * between SeaBIOS and our first log line. Raising this means extending
 * build_pagetables first.
 */
#define MAP_LIMIT 0x100000000UL

/* claim every usable RAM range the loader reported, minus our own
 * image and the low megabyte.
 *
 * Without this the heap was a hardcoded 16MB-128MB whatever the
 * machine had: a larger -m went unused, and a smaller one put pages
 * that do not exist on the free list -- latent until an allocation
 * walked far enough to touch one.
 *
 * returns the number of regions taken, so the caller can tell a parsed
 * map from the fallback.
 */
static int
claim_memory(unsigned long start_info)
{
	const struct hvm_start_info *si =
	    (const struct hvm_start_info *)start_info;
	const struct hvm_memmap_table_entry *map;
	uintptr_t image_end = (uintptr_t)__image_end;
	int taken = 0;

	if (!si || si->magic != PVH_START_MAGIC || si->version < 1 ||
	    si->memmap_paddr == 0 || si->memmap_entries == 0)
		return 0;

	map = (const struct hvm_memmap_table_entry *)(uintptr_t)si->memmap_paddr;

	for (uint32_t i = 0; i < si->memmap_entries; i++) {
		uintptr_t base = (uintptr_t)map[i].addr;
		uintptr_t end = base + (uintptr_t)map[i].size;

		if (map[i].type != PVH_MEMMAP_TYPE_RAM)
			continue;
		if (base < LOW_LIMIT)
			base = LOW_LIMIT;
		if (end > MAP_LIMIT)
			end = MAP_LIMIT;
		if (base >= MAP_LIMIT)
			continue;
		/* our own image, and the start_info and memmap the loader
		 * placed for us, all live low; starting after the image
		 * covers them without needing to know where each one is.
		 */
		if (base < image_end)
			base = image_end;
		if (end <= base)
			continue;

		pmm_add(base, end - base);
		taken++;
	}
	return taken;
}

void
microvm_main(unsigned long start_info)
{
	uart_init();
	tsc_calibrate();
	if (claim_memory(start_info) == 0)
		pmm_add(FALLBACK_BASE, FALLBACK_LEN);
	idt_init();
	ioapic_init();	/* mask every line before enabling anything */
	lapic_init();

	/* boot.S entered with interrupts off and nothing turned them back
	 * on, so until now every vector was dead: the LAPIC timer could be
	 * armed and would never deliver, and efi_shim's WaitForEvent would
	 * have halted forever waiting for a tick that could not arrive.
	 *
	 * Safe to enable here because the IDT is loaded, every IOAPIC line
	 * is masked, and the LAPIC timer's LVT entry is masked until
	 * something arms it. The only line that can fire is one a driver
	 * has explicitly routed.
	 */
	__asm__ volatile ("sti");

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
