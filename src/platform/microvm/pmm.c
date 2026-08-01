/* bump/freelist physical allocator, in the shape of 9front's xalloc.c
 * (sys/src/9/port/xalloc.c): one first-fit hole list, seeded from a
 * single carved-out range rather than a parsed PVH memory map.
 *
 * parsing hvm_start_info's real memmap is future work (see
 * docs/microvm-plan.md); qemu's microvm always gives at least the low
 * megabytes below any MMIO hole, so hardcoding a range below 512MB is
 * safe for -m values this small slice is tested with.
 *
 * no coalescing on free: freed blocks rejoin the list as-is. fine for
 * a boot-to-serial smoke test; would fragment badly under sustained
 * churn, which is exactly the kind of cost the parked plan's virtio-9p
 * phase should revisit this allocator for.
 */

#include <stddef.h>
#include <stdint.h>

#include "microvm.h"

struct pmm_block {
	size_t size;
	struct pmm_block *next;
};

static struct pmm_block *freelist;
static size_t arena_bytes;

#define ALIGN 16

static size_t
align_up(size_t n)
{
	return (n + (ALIGN - 1)) & ~(size_t)(ALIGN - 1);
}

void
pmm_init(uintptr_t base, size_t len)
{
	struct pmm_block *b = (struct pmm_block *)base;

	b->size = len;
	b->next = 0;
	freelist = b;
	arena_bytes = len;
}

/* what the machine has, and what is left of it.
 *
 * total is the carved range pmm_init was handed, not the machine's RAM:
 * until hvm_start_info's memmap is parsed that range is a hardcoded
 * slice, so this under-reports a larger -m. avail walks the hole list,
 * which is exact but says nothing about the largest single request that
 * can still be met, since nothing coalesces on free.
 */
void
pmm_meminfo(size_t *total, size_t *avail)
{
	size_t a = 0;

	for (struct pmm_block *b = freelist; b; b = b->next)
		a += b->size;
	if (total)
		*total = arena_bytes;
	if (avail)
		*avail = a;
}

void *
pmm_alloc(size_t n)
{
	n = align_up(n);
	if (n < sizeof(struct pmm_block))
		n = sizeof(struct pmm_block);

	struct pmm_block **pp = &freelist;

	while (*pp) {
		struct pmm_block *b = *pp;

		if (b->size >= n) {
			if (b->size >= n + sizeof(struct pmm_block)) {
				struct pmm_block *rem =
				    (struct pmm_block *)((char *)b + n);

				rem->size = b->size - n;
				rem->next = b->next;
				*pp = rem;
			} else {
				*pp = b->next;
			}
			return b;
		}
		pp = &b->next;
	}
	return 0;
}

void
pmm_free(void *p, size_t n)
{
	struct pmm_block *b = p;

	n = align_up(n);
	if (n < sizeof(struct pmm_block))
		n = sizeof(struct pmm_block);
	b->size = n;
	b->next = freelist;
	freelist = b;
}
