#ifndef CPU_H
#define CPU_H

/* one of these per cpu, and the place everything that is currently a
 * bare static in kernel.c is headed.
 *
 * It is nearly empty at this commit on purpose: the cpus are brought
 * up and parked, and nothing schedules on them yet, so the only fields
 * are the two that say which cpu this is. The run queues, the current
 * proc and the allocator cache arrive with the commits that move them
 * off their globals, one at a time, rather than as a struct full of
 * fields nothing reads.
 *
 * Arch-blind, because kernel.c is: how a cpu finds its own struct is
 * the arch's business (%gs on x86_64) and does not belong here.
 */

struct cpu {
	unsigned idx;		/* 0 is the boot processor, always */
	unsigned apicid;	/* what the hardware calls it */
};

struct cpu *cpu_at(unsigned i);

#endif
