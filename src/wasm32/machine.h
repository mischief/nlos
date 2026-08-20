#ifndef MACHINE_H
#define MACHINE_H

/* the arch primitives that are one instruction elsewhere. wasm has
 * neither: this port is uniprocessor, so machine_relax is reached only
 * through lock.h's NCPU == 1 path where nothing spins, and there is no
 * cycle counter to read -- machine_cycles answers 0, which the lock
 * statistics understand as "not measured".
 */

static inline void
machine_relax(void)
{
}

static inline unsigned long long
machine_cycles(void)
{
	return 0;
}

#endif
