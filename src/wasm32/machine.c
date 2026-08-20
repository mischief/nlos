/* wasm32 machine bits: the clock and the halt, both the host's. */

#include "host.h"
#include "platform.h"

unsigned long long
platform_ticks(void)
{
	return host_now_ns();
}

_Noreturn void
machine_halt(void)
{
	host_exit(0);
}

const char *
platform_arch(void)
{
	return "wasm32";
}
