#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

#include "efi.h"
#include "fs.h"
#include "kernel.h"
#include "platform.h"
#include "cpu.h"


EFI_SYSTEM_TABLE *ST;
EFI_BOOT_SERVICES *BS;
EFI_HANDLE self_image;

extern void console_write(const char *s, UINTN n);


EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);

EFI_STATUS
efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	EFI_INPUT_KEY key;
	UINTN index;

	ST = st;
	BS = st->BootServices;
	self_image = image;

	ST->ConOut->ClearScreen(ST->ConOut);

	/* first, so every line after it can be stamped */
	kernel_clock_init();

	char cbuf[96];

	kernel_log("boot: lua-os starting");
	snprintf(cbuf, sizeof cbuf, "clock: %llu cycles/ms (100ms calibration)",
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

	if (fs_init() != 0)
		kernel_log("boot: no filesystem on boot volume");

	uart_takeover();	/* wrest the wire port from the firmware before we poll it */

	if (kernel_init() != 0) {
		kernel_log("boot: kernel_init FAILED");
		goto out;
	}
	/* test harness: a payload injected via qemu fw_cfg replaces
	 * /init.lua as proc 0 (see scripts/boottest.sh)
	 */
	char *testbuf;
	size_t testlen;

	if (fwcfg_load("opt/org.luaos.test", &testbuf, &testlen) == 0) {
		kernel_log("boot: running fw_cfg test payload");
		if (kernel_spawn_buffer(testbuf, testlen) < 0) {
			kernel_log("boot: FAILED to spawn test payload");
			goto out;
		}
		free(testbuf);
	} else if (kernel_spawn_file("/init.lua") < 0) {
		kernel_log("boot: FAILED to spawn /init.lua");
		goto out;
	}
	kernel_run();

out:
	kernel_log("boot: halted; press any key to exit");
	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_NOT_READY)
		BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
	return EFI_SUCCESS;
}

/* the one cpu, and so a plain static rather than anything found
 * through a register. cpu_self() is still the only way kernel.c
 * reaches it, which is what keeps that file free of the distinction.
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

/* one cpu, always. EFI's other processors are reachable only through
 * EFI_MP_SERVICES_PROTOCOL, and an AP started that way still may not
 * call firmware -- which is most of what this platform does. So the
 * question is not open here the way it is on microvm.
 */
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

/* never reached: efi has one cpu and only the boot processor's loop,
 * which sleeps through firmware's WaitForEvent instead.
 */
void
platform_cpu_idle(void)
{
}
