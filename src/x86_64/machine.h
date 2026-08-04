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

/* the per-cpu pointer, kept in the gs base and read back through a
 * gs-relative load of offset 0 -- struct cpu's first member is a
 * pointer to itself for exactly this.
 *
 * IA32_GS_BASE and not KERNEL_GS_BASE with swapgs: swapgs exists to
 * get a per-cpu pointer back after entering the kernel from user
 * mode, and there is no user mode here. Nothing else in this kernel
 * uses gs, so it is unclaimed.
 */
#define IA32_GS_BASE 0xC0000101

static inline void *
machine_cpu_self(void)
{
	void *p;

	__asm__ volatile ("movq %%gs:0, %0" : "=r" (p));
	return p;
}

static inline void
machine_set_cpu_self(void *p)
{
	unsigned long long v = (unsigned long long)p;

	__asm__ volatile ("wrmsr"
	    : : "c" (IA32_GS_BASE), "a" ((unsigned)v),
	        "d" ((unsigned)(v >> 32)));
}

#endif
