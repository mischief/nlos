/* the wasm boot sequence, exported as "boot" for the embedder to call.
 *
 * The order matches every other platform -- console, clock, filesystem,
 * kernel, first proc -- because kernel.c depends on it: a log line needs
 * a clock, and the first proc needs a root to load from.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "fs.h"
#include "host.h"
#include "kernel.h"
#include "platform.h"
#include "wasm.h"

#define BOOT_PAYLOAD "/init.lua"

/* the default machine. The embedder may ask for another size; nothing
 * else about this machine is configurable.
 */
#define DEFAULT_MEM (64ULL * 1024 * 1024)

_Noreturn void
platform_abort(const char *why)
{
	console_write(why, __builtin_strlen(why));
	console_write("\n", 1);
	host_exit(1);
}

void
platform_watchdog(unsigned secs)
{
	(void)secs;	/* nothing here can reset the machine on its own */
}

__attribute__((export_name("boot")))
void
wasm_boot(unsigned long long membytes)
{
	char cbuf[96];
	char *payload;
	size_t len;

	mem_init(membytes ? membytes : DEFAULT_MEM);
	kernel_clock_init();

	if (fs_init() != 0)
		kernel_say("boot: fs_init FAILED (the embed has no failure mode)");

	kernel_say("boot: lua-os starting (wasm)");

	{
		unsigned long long total = 0, avail = 0;

		platform_meminfo(&total, &avail, NULL);
		snprintf(cbuf, sizeof cbuf, "mem: %lluK total, %lluK available",
		    total / 1024, avail / 1024);
		kernel_say(cbuf);
	}

	if (kernel_init() != 0)
		platform_abort("boot: kernel_init FAILED");

	if (embed_load(BOOT_PAYLOAD, &payload, &len) != 0)
		platform_abort("boot: no " BOOT_PAYLOAD " in the module");
	if (kernel_spawn_buffer(payload, len) < 0)
		platform_abort("boot: FAILED to spawn " BOOT_PAYLOAD);
	free(payload);

	kernel_run();

	kernel_say("boot: halted (every proc exited)");
	machine_halt();
}
