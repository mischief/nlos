#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives that are one instruction, and so are inline
 * rather than a call in machine.c.
 */

/* the hint a spin loop gives the core it is running on. On x86 pause
 * also stops the memory-order speculation that makes leaving a spin
 * loop expensive, so it is not only a power hint.
 */
static inline void
machine_relax(void)
{
	__asm__ volatile ("pause" ::: "memory");
}

#endif
