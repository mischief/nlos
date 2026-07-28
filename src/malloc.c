/* malloc over EFI boot services pool.
 * 16-byte header keeps the size (so realloc can copy) and a magic word
 * we validate on free/realloc to catch double-frees and heap
 * corruption loudly instead of scribbling the pool.
 */

#include <stdlib.h>
#include <string.h>
#include "efi.h"

extern _Noreturn void platform_abort(const char *why);

struct hdr {
	size_t size;
	size_t magic;
};

#define MAGIC 0x6c75616f73ULL	/* "luaos" */

/* accounting for everything NOT on a lua heap: port messages, net
 * tokens and payload copies, the loadfile buffers, and our own 16-byte
 * headers. per-proc lua heaps are tracked separately by kernel.c's
 * allocator hook, so these two together are the whole picture.
 *
 * requested bytes only -- AllocatePool's own rounding and pool metadata
 * are firmware-internal and not visible to us, so real pool usage is
 * somewhat higher than live_bytes.
 */
static size_t live_bytes, peak_bytes;
static unsigned long live_blocks, total_blocks;

void malloc_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);

void
malloc_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total)
{
	if (live)
		*live = live_bytes;
	if (peak)
		*peak = peak_bytes;
	if (blocks)
		*blocks = live_blocks;
	if (total)
		*total = total_blocks;
}

void *
malloc(size_t n)
{
	struct hdr *h;
	void *p = 0;

	if (BS->AllocatePool(EfiLoaderData, n + sizeof *h, &p) != EFI_SUCCESS)
		return 0;
	h = p;
	h->size = n;
	h->magic = MAGIC;
	live_bytes += n + sizeof *h;
	if (live_bytes > peak_bytes)
		peak_bytes = live_bytes;
	live_blocks++;
	total_blocks++;
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
	live_bytes -= h->size + sizeof *h;
	live_blocks--;
	BS->FreePool(h);
}

void *
calloc(size_t nmemb, size_t size)
{
	if (size != 0 && nmemb > (size_t)-1 / size)
		return 0;	/* nmemb * size would overflow */

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
