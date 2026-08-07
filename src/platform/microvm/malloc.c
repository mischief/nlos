/* malloc over pmm.c's bump/freelist arena. same 16-byte
 * size+magic header as src/platform/efi/malloc.c, so kernel.c's
 * accounting and double-free detection behave identically on both
 * platforms.
 */

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern _Noreturn void platform_abort(const char *why);
void	*pmm_alloc(size_t n);
void	pmm_free(void *p, size_t n);
void	pmm_meminfo(size_t *total, size_t *avail);

struct hdr {
	size_t size;
	size_t magic;
};

#define MAGIC 0x6c75616f73ULL	/* "luaos" */

/* diagnostics, and the only things here two cpus touch at once: the
 * arena underneath is locked, but these sit outside it. Relaxed is
 * the right order for all four -- nothing is published through them
 * and no one draws a conclusion from the order two of them changed
 * in. peak needs the compare-exchange loop rather than a load and a
 * store, since between those two a larger value can be lost.
 */
static atomic_size_t live_bytes, peak_bytes;
static atomic_ulong live_blocks, total_blocks;

static void
note_peak(size_t live)
{
	size_t seen = atomic_load_explicit(&peak_bytes, memory_order_relaxed);

	while (live > seen &&
	    !atomic_compare_exchange_weak_explicit(&peak_bytes, &seen, live,
	    memory_order_relaxed, memory_order_relaxed))
		;
}

void kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);

void
kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total)
{
	if (live)
		*live = atomic_load_explicit(&live_bytes, memory_order_relaxed);
	if (peak)
		*peak = atomic_load_explicit(&peak_bytes, memory_order_relaxed);
	if (blocks)
		*blocks = atomic_load_explicit(&live_blocks,
		    memory_order_relaxed);
	if (total)
		*total = atomic_load_explicit(&total_blocks,
		    memory_order_relaxed);
}

void *
malloc(size_t n)
{
	struct hdr *h = pmm_alloc(n + sizeof *h);

	if (!h)
		return 0;
	h->size = n;
	h->magic = MAGIC;
	note_peak(atomic_fetch_add_explicit(&live_bytes, n + sizeof *h,
	    memory_order_relaxed) + n + sizeof *h);
	atomic_fetch_add_explicit(&live_blocks, 1, memory_order_relaxed);
	atomic_fetch_add_explicit(&total_blocks, 1, memory_order_relaxed);
	return h + 1;
}

void
free(void *p)
{
	struct hdr *h;

	if (!p)
		return;
	h = (struct hdr *)p - 1;
	if (h->magic != MAGIC)
		platform_abort("free: bad heap magic (double free or corruption)");
	h->magic = 0;
	atomic_fetch_sub_explicit(&live_bytes, h->size + sizeof *h,
	    memory_order_relaxed);
	atomic_fetch_sub_explicit(&live_blocks, 1, memory_order_relaxed);
	pmm_free(h, h->size + sizeof *h);
}

/* the efi platform sums the firmware's memory map for this; here the
 * arena is our own, so pmm.c already knows both numbers.
 */
void platform_meminfo(unsigned long long *total, unsigned long long *avail);

void
platform_meminfo(unsigned long long *total, unsigned long long *avail)
{
	size_t t = 0, a = 0;

	pmm_meminfo(&t, &a);
	if (total)
		*total = t;
	if (avail)
		*avail = a;
}

void *
calloc(size_t nmemb, size_t size)
{
	if (size != 0 && nmemb > (size_t)-1 / size)
		return 0;

	size_t n = nmemb * size;
	void *p = malloc(n);

	if (p)
		memset(p, 0, n);
	return p;
}

void *
realloc(void *p, size_t n)
{
	struct hdr *h;
	void *q;

	if (!p)
		return malloc(n);
	if (n == 0) {
		free(p);
		return 0;
	}
	h = (struct hdr *)p - 1;
	if (h->magic != MAGIC)
		platform_abort("realloc: bad heap magic (double free or corruption)");
	q = malloc(n);
	if (!q)
		return 0;
	memcpy(q, p, h->size < n ? h->size : n);
	free(p);
	return q;
}

/* one kind of memory here, so the lua heap's chunks are ordinary
 * allocations. See platform.h: the hook exists for the esp32, which has
 * two and must be told which.
 */
void *platform_chunk_alloc(size_t n);
void platform_chunk_free(void *p, size_t n);

/* the lua heap's chunks come from malloc here, which is the same pool
 * platform_meminfo reports: one kind of memory, one set of figures.
 */
void platform_chunkinfo(unsigned long long *total, unsigned long long *avail);

void
platform_chunkinfo(unsigned long long *total, unsigned long long *avail)
{
	platform_meminfo(total, avail);
}

void *
platform_chunk_alloc(size_t n)
{
	return malloc(n);
}

void
platform_chunk_free(void *p, size_t n)
{
	(void)n;
	free(p);
}
