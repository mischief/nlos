/* riscv64 machine bits */
#include "platform.h"

/* the `time` csr, via the rdtime pseudo-instruction. like rdtsc it is a
 * free-running tick count at a fixed rate -- but a far slower one:
 * 10MHz on qemu's virt machine, against 62.5MHz for the arm virtual
 * counter and a GHz for a TSC. that is fine, because nothing here uses
 * raw ticks as a duration: boot calibrates against BS->Stall.
 *
 * we run in S-mode under OpenSBI, which enables mcounteren.TM for us;
 * even where it does not, SBI emulates the read from its illegal
 * instruction trap, so this cannot fault. deliberately not fenced --
 * rdtsc is not either, and one tick of skew is far below the
 * resolution anyone reads this at.
 */
unsigned long long
platform_ticks(void)
{
	unsigned long long v;

	__asm__ volatile ("rdtime %0" : "=r" (v));
	return v;
}

_Noreturn void
machine_halt(void)
{
	for (;;)
		__asm__ volatile ("wfi");
}

const char *
platform_arch(void)
{
	return "riscv64";
}
