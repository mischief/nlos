#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives that are one instruction, and so are inline
 * rather than a call in machine.c. This port is uniprocessor, so
 * machine_relax is only ever reached through lock.h's NCPU == 1 path,
 * where nothing spins -- it is here so that lock.h needs no #ifdef.
 *
 * Zihintpause is not in the -march this build asks for, and its
 * encoding is a hint that decodes as a nop on a core without it. Spell
 * it out rather than raise the baseline for one instruction nothing
 * currently executes.
 */

static inline void
machine_relax(void)
{
	__asm__ volatile (".insn i 0x0F, 0, x0, x0, 0x010" ::: "memory");
}

#endif
