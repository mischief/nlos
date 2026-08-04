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

#endif
