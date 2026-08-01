/* first-fit physical allocator, in the shape of 9front's xalloc.c
 * (sys/src/9/port/xalloc.c): one hole list, seeded by pmm_add with
 * whatever usable ranges main.c found in the PVH memory map. Several
 * regions are ordinary -- a machine with RAM either side of the MMIO
 * hole contributes one each.
 *
 * The list is kept in address order so that a free can merge with the
 * blocks either side of it. That ordering is the only reason the merge
 * is affordable: adjacency is a question about neighbours, and only an
 * ordered list knows who they are.
 *
 * It used to skip the merge, and the cost was not the wasted bytes but
 * the length of the list. A caller that allocates in a loop -- which is
 * every port message, since serialize() grows its buffer by doubling --
 * freed a 256, a 512, a 1024 and so on, each becoming a hole of a size
 * nothing else asked for. The list grew without bound and first-fit
 * walked all of it, so the same 4K message round trip measured 116us
 * on its first hundred and 184us four hundred later, with no upper
 * limit short of a reboot.
 *
 * Note that sizes stay multiples of ALIGN throughout, which is what
 * keeps a split from leaving a remainder too small to describe: pmm_add
 * aligns both ends of a region inward, and ALIGN is exactly
 * sizeof(struct pmm_block), so a block that cannot be split is always
 * exactly the size asked for and never a few bytes more.
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

/* put a block back in address order, merging with either neighbour it
 * turns out to be adjacent to. Both merges matter and for different
 * reasons: forward is the block freed just before its successor,
 * backward is a chunk handed back to the hole it was split from.
 *
 * O(holes), but coalescing is what keeps that count from growing, so
 * this pays for itself -- the walk it costs is the walk it prevents
 * pmm_alloc from making on every subsequent request.
 */
static void
freelist_insert(struct pmm_block *b)
{
	struct pmm_block *prev = 0, *cur = freelist;

	while (cur && cur < b) {
		prev = cur;
		cur = cur->next;
	}

	if (cur && (char *)b + b->size == (char *)cur) {
		b->size += cur->size;
		b->next = cur->next;
	} else {
		b->next = cur;
	}

	if (!prev)
		freelist = b;
	else if ((char *)prev + prev->size == (char *)b) {
		prev->size += b->size;
		prev->next = b->next;
	} else
		prev->next = b;
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

	/* inward at BOTH ends: an end left unaligned would make this
	 * region's size a non-multiple of ALIGN, and every remainder split
	 * off it thereafter would inherit that, which is what would let a
	 * block be a few bytes larger than the request it satisfies -- a
	 * few bytes that pmm_free is never told about and that would sit
	 * between two holes keeping them from merging.
	 */
	base = align_up(base);
	end &= ~(uintptr_t)(ALIGN - 1);
	if (end <= base || end - base < sizeof(struct pmm_block))
		return;

	b = (struct pmm_block *)base;
	b->size = end - base;
	arena_bytes += b->size;
	freelist_insert(b);
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
	freelist_insert(b);
}
