#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives that are one instruction, and so are inline
 * rather than a call in machine.c. This port is uniprocessor, so
 * machine_relax is only ever reached through lock.h's NCPU == 1 path,
 * where nothing spins -- it is here so that lock.h needs no #ifdef.
 */

static inline void
machine_relax(void)
{
	__asm__ volatile ("yield" ::: "memory");
}

/* the virtual counter, for measuring something too short to reach a
 * clock through a function call. It runs at CNTFRQ_EL0, 62.5MHz under
 * qemu, so it is far coarser than a TSC; it is meant to be summed over
 * many events rather than trusted for one.
 */
static inline unsigned long long
machine_cycles(void)
{
	unsigned long long v;

	__asm__ volatile ("mrs %0, cntvct_el0" : "=r" (v));
	return v;
}

#endif
