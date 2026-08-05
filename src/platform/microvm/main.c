/* microvm boot sequence -- the bare-metal analogue of
 * src/platform/efi/main.c's efi_main, called from boot.S's
 * long_mode_entry once paging/long mode/GDT are live.
 *
 * The boot payload comes in over fw_cfg, the same mechanism
 * src/platform/efi/main.c uses for its test harness, but here it is how
 * code starts rather than just the test path: there is no disk and no
 * /init.lua on an ESP to fall back on. What a payload then mounts is
 * its own business -- virtio-9p is available to it (see fs.c) -- but
 * something has to run first to do the mounting.
 *
 * When fw_cfg has nothing, that something is BOOT_PAYLOAD out of the
 * embedded set. Not a convenience: OpenBSD vmd's fw_cfg serves a fixed
 * list and cannot be handed a host file at all, so on that loader the
 * injected path does not exist and this is the only one left.
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

#define BOOT_PAYLOAD "/boot/microvm.lua"	/* see meson.build embed_files */

/* what to fall back on when the map cannot be read: 16MB-128MB, above
 * our own image (linked at 1MB, well under 16MB even with Lua linked
 * in) and inside the smallest -m worth booting. Unreachable under
 * qemu's microvm, which always supplies a version 1 start_info; it is
 * the whole memory story on a loader that enters at e_entry with no
 * start_info at all (boot.S's entry_elf, OpenBSD vmd), where it also
 * has to stay clear of the PCI hole vmd opens at 0xf0000000 -- 128MB
 * is nowhere near it.
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
	static const char entered[] = "luaos: entered\n";

	uart_init();

	/* the earliest thing that can speak, and it exists for bring-up on
	 * a loader nobody has booted this on before: everything below --
	 * the memory map, the idt, the apic -- can die with no output at
	 * all, and without this line a dead guest cannot be told apart
	 * from one that was never entered. Raw PIO, before any allocator
	 * or clock, so it depends on nothing but uart_init.
	 */
	console_write(entered, sizeof entered - 1);

	tsc_calibrate();
	if (claim_memory(start_info) == 0)
		pmm_add(FALLBACK_BASE, FALLBACK_LEN);
	idt_init();
	smp_init();		/* cpu 0, before anything calls cpu_self() */
	intr_init();	/* mask every line before enabling anything */

	/* boot.S entered with interrupts off and nothing turned them back
	 * on, so until now every vector was dead: the LAPIC timer could be
	 * armed and would never deliver, and efi_shim's WaitForEvent would
	 * have halted forever waiting for a tick that could not arrive.
	 *
	 * Safe to enable here because the IDT is loaded and intr_init left
	 * every line of whichever controller this machine has masked. The
	 * only line that can fire is one a driver has explicitly routed.
	 */
	__asm__ volatile ("sti");

	/* after sti and after the controller is masked: routing the line is
	 * the last step, so nothing can fire into a half-built machine.
	 */
	uart_irq_enable();

	kernel_clock_init();

	if (fs_init() != 0)
		kernel_log("boot: fs_init FAILED (unexpected: embed has no failure mode)");

	char cbuf[96];

	kernel_log("boot: lua-os starting (microvm)");
	snprintf(cbuf, sizeof cbuf, "clock: %llu cycles/ms (%s)",
	    kernel_cyc_per_ms(), tsc_source());
	kernel_log(cbuf);

	/* an uncalibrated clock is wrong by a constant factor, which
	 * nothing inside the guest can measure, so say so here or it goes
	 * unnoticed until a timeout somewhere fires at the wrong length.
	 */
	if (tsc_hz() == 1000000000ULL)
		kernel_log("clock: WARNING no frequency source answered; "
		    "every timeout in the system is suspect");

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
	} else if (embed_load(BOOT_PAYLOAD, &testbuf, &testlen) == 0) {
		kernel_log("boot: no fw_cfg payload; running " BOOT_PAYLOAD);
		if (kernel_spawn_buffer(testbuf, testlen) < 0) {
			kernel_log("boot: FAILED to spawn boot payload");
			machine_reset();
		}
		free(testbuf);
	} else {
		kernel_log("boot: no fw_cfg payload and no embedded one -- nothing to run");
		machine_reset();
	}

	/* the other cpus last, and after the first proc exists.
	 *
	 * An AP goes straight into the dispatch loop, whose condition is
	 * that the machine has live procs. Started any earlier there are
	 * none, so it falls out of the loop at once and parks for good --
	 * which is what happened, and cost nothing but every proc
	 * landing on cpu 0 with no error anywhere to say why.
	 *
	 * It still has to be after intr_init, since starting a cpu is an
	 * IPI and needs the local APIC.
	 */
	smp_start_aps();

	kernel_run();

	kernel_log("boot: halted (every proc exited)");
	machine_reset();
}
