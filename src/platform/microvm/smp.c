/* bringing up the other cpus.
 *
 * This is bring-up only: an AP arrives in ap_main, records itself, and
 * parks. Nothing schedules on it yet. Landing that alone is deliberate
 * -- the sequence below is the part that either works or hangs the
 * machine with no output, and it is worth knowing it works before
 * anything depends on it.
 *
 * How the cpus are found, given this platform has no ACPI to ask (see
 * intr.c and microvm.h for why): fw_cfg says how many there are, and
 * the MP spec says that in a default configuration -- which is what
 * qemu builds -- local APIC ids are "numbered sequentially, starting at
 * zero". So a count is a complete description of the machine here, and
 * no table walk would tell us anything the count does not.
 *
 * That is also why they are started one at a time rather than with the
 * all-but-self broadcast. Naming each AP costs nothing once the ids are
 * known, and buys three things: each AP is handed its own stack at a
 * fixed address instead of racing for one, each gets its own timeout,
 * and a cpu that fails to start is reported as that cpu rather than as
 * a wrong total.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "microvm.h"
#include "platform.h"
#include "smp.h"
#include "cpu.h"

/* the boot stack in boot.S is 64K, and an AP does the same work on
 * its own, so match it. These are static rather than allocated
 * because bring-up runs before there is much of an allocator and a
 * stack that failed to allocate is not a case worth having.
 */
#define APSTACK 65536

extern unsigned char smp_tramp_start[], smp_tramp_end[];
void	ap_main(unsigned idx);

static unsigned char apstacks[NCPU - 1][APSTACK] __attribute__((aligned(16)));

static struct cpu cpus[NCPU];
static unsigned ncpu = 1;	/* the BSP is cpu 0 and is already here */

/* set by an AP once it is far enough along to say so, read by the BSP
 * spinning on it. Atomic because that is exactly a value written by
 * one cpu and read by another while it changes.
 */
static atomic_uint online;

struct cpu *
cpu_at(unsigned i)
{
	return i < ncpu ? &cpus[i] : 0;
}

unsigned
platform_ncpu(void)
{
	return ncpu;
}

/* how many cpus qemu gave us. fw_cfg key 0x05 is NB_CPUS, a 16-bit
 * little-endian count of the cpus present -- not etc/max-cpus, which
 * is the hotplug ceiling and is usually larger.
 *
 * Everything about this is a qemu fact rather than an x86 one, so a
 * machine that is not qemu answers 0 or nothing and gets 1, which is
 * the honest answer for a machine we cannot enumerate.
 */
static unsigned
fwcfg_ncpus(void)
{
	uint16_t n = 0;

	if (fwcfg_key(0x05, &n, sizeof n) != 0)
		return 1;
	if (n < 1 || n > NCPU)
		return n < 1 ? 1 : NCPU;
	return n;
}

/* what an AP runs, and the first code on that cpu written in C.
 *
 * It cannot do very much yet: there is no per-cpu scheduler, and it
 * must not touch anything the BSP is using without a lock. So it
 * enables its own local APIC -- an AP arrives with its LAPIC in
 * whatever state a SIPI leaves, which is not enabled -- publishes
 * itself, and parks.
 *
 * The park is hlt with interrupts disabled, which is a cpu that will
 * never wake. That is correct for now and is the thing the next commit
 * replaces: an idle cpu has to be woken by an IPI when work arrives,
 * and until there is work to send it, a wakeable idle loop would only
 * be a spin with extra steps.
 */
void
ap_main(unsigned idx)
{
	struct cpu *c = &cpus[idx];

	c->idx = idx;
	c->apicid = lapic_id();

	lapic_init();

	/* publish last: the BSP takes this as "cpu idx is up and its
	 * struct is filled in", so everything above has to have
	 * happened first. Release pairs with the BSP's acquire.
	 */
	atomic_store_explicit(&online, idx, memory_order_release);

	for (;;)
		__asm__ volatile ("cli; hlt");
}

/* start one AP and wait for it to say it arrived.
 *
 * The wait is bounded and its expiry is not fatal: a cpu that does not
 * come up is one cpu, and a machine that boots on the rest is better
 * than one that does not boot. Returns 0 if it arrived.
 */
static int
startap(unsigned idx, unsigned apicid)
{
	volatile uint64_t *slot = (volatile uint64_t *)
	    (uintptr_t)SMP_TRAMP_BASE;

	atomic_store_explicit(&online, ~0u, memory_order_relaxed);

	slot[SMP_OFF_STACK / 8] =
	    (uint64_t)(uintptr_t)(apstacks[idx - 1] + APSTACK);
	slot[SMP_OFF_INDEX / 8] = idx;

	lapic_startap(apicid, SMP_TRAMP_BASE);

	for (int i = 0; i < 1000; i++) {
		if (atomic_load_explicit(&online, memory_order_acquire) == idx)
			return 0;
		platform_stall_us(1000);
	}
	return -1;
}

/* called from microvm_main once the interrupt controller is up and
 * before anything wants a second cpu.
 */
void
smp_init(void)
{
	unsigned want;

	cpus[0].idx = 0;

	/* no LAPIC is no IPI, and so no way to start anything. That is
	 * OpenBSD vmd, where vmm masks CPUID_APIC out -- see intr.c.
	 * It is a uniprocessor by construction, not by configuration.
	 */
	if (!intr_have_apic()) {
		return;
	}

	cpus[0].apicid = lapic_id();

	want = fwcfg_ncpus();
	if (want <= 1)
		return;

	/* the trampoline has to be somewhere an AP can start, which is
	 * below 1MB, and it is linked up with the rest of the kernel.
	 * Nothing else uses this page: claim_memory never offers the
	 * allocator anything under 0x100000.
	 */
	memcpy((void *)(uintptr_t)SMP_TRAMP_BASE, smp_tramp_start,
	    (size_t)(smp_tramp_end - smp_tramp_start));

	for (unsigned i = 1; i < want; i++) {
			if (startap(i, i) == 0)
			ncpu++;
		}
}
