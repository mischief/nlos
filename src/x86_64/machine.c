/* x86_64 machine bits */
#include "platform.h"

unsigned long long
platform_ticks(void)
{
	unsigned int lo, hi;

	__asm__ volatile ("rdtsc" : "=a" (lo), "=d" (hi));
	return ((unsigned long long)hi << 32) | lo;
}

_Noreturn void
machine_halt(void)
{
	for (;;)
		__asm__ volatile ("hlt");
}

const char *
platform_arch(void)
{
	return "x86_64";
}
