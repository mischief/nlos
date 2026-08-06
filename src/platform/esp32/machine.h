#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives lock.h and kernel.c reach for, on the one
 * platform whose kernel is built by ESP-IDF rather than meson.
 *
 * It lives beside the platform rather than under an arch directory
 * because this port has two of them: an xtensa S3 and a RISC-V C5 build
 * the same sources, and IDF supplies the instruction either way. The
 * other ports put this in src/<arch>/, where one arch is one machine.
 *
 * Uniprocessor: NCPU is 1 here, so lock.h compiles every lock down to a
 * compiler barrier and machine_relax is never reached. Both are here so
 * that lock.h needs no #ifdef, which is the arrangement the aarch64 and
 * riscv64 headers describe.
 */

#include <esp_cpu.h>

/* what a spinning cpu does while it waits. Nothing spins on this
 * platform; the definition exists for the contract.
 */
static inline void
machine_relax(void)
{
	__asm__ volatile ("" ::: "memory");
}

/* the cpu's own cycle counter, for measuring something too short to
 * reach a clock through a function call -- kernel.c sums it over ipc
 * lock acquisitions.
 *
 * 32 bits wide, so it wraps every 18 seconds at 240MHz. That is a
 * property this counter has and platform_ticks deliberately does not:
 * ticks must be free running and 64-bit, which is why that one is
 * esp_timer's microseconds instead. Here the value is only ever
 * subtracted from a later reading of itself to get a short interval,
 * and a wrap in between gives one wrong summand in a total meant to be
 * read as an order of magnitude.
 */
static inline unsigned long long
machine_cycles(void)
{
	return esp_cpu_get_cycle_count();
}

#endif
