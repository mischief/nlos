/* bump/freelist physical allocator, in the shape of 9front's xalloc.c
 * (sys/src/9/port/xalloc.c): one first-fit hole list, seeded by
 * pmm_add with whatever usable ranges main.c found in the PVH memory
 * map. Several regions are ordinary -- a machine with RAM either side
 * of the MMIO hole contributes one each.
 *
 * no coalescing on free: freed blocks rejoin the list as-is, and two
 * adjacent frees stay two blocks forever. So the largest request that
 * can still be met shrinks under churn even while the free total does
 * not, and pmm_meminfo's avail cannot be read as "a block this big is
 * available". Fine while allocation is dominated by a few long-lived
 * lua heaps; wrong the moment anything allocates in a loop.
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

/* hand the allocator a usable range. the block header lives in the
 * range itself, so anything too small to hold one is dropped rather
 * than scribbled on.
 */
void
pmm_add(uintptr_t base, size_t len)
{
	uintptr_t end = base + len;
	struct pmm_block *b;

	base = align_up(base);
	if (end <= base || end - base < sizeof(struct pmm_block))
		return;

	b = (struct pmm_block *)base;
	b->size = end - base;
	b->next = freelist;
	freelist = b;
	arena_bytes += b->size;
}

/* what the machine has, and what is left of it.
 *
 * total is everything pmm_add was given, so it is the machine's usable
 * RAM less our own image rather than its -m. avail walks the hole list;
 * see the header on why it is not the largest allocatable block.
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
