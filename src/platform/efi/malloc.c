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

void kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);

void
kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
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

/* what the firmware says the machine has.
 *
 * there is no "free memory" call, so sum the map. EfiConventionalMemory
 * is what remains available; adding the types holding code and data
 * already handed out approximates the RAM present. reserved, unusable and
 * memory-mapped ranges are left out, since counting those as RAM would
 * report a machine larger than it is.
 *
 * worth having because malloc reaches AllocatePool directly instead of
 * carving an arena: free conventional memory is the real remaining budget,
 * and a proc is a lua_State drawn from it.
 */
void platform_meminfo(unsigned long long *total, unsigned long long *avail);

void
platform_meminfo(unsigned long long *total, unsigned long long *avail)
{
	UINTN size = 0, mapkey = 0, dsize = 0;
	UINT32 dver = 0;
	EFI_MEMORY_DESCRIPTOR *map = 0;
	unsigned long long t = 0, a = 0;

	if (total)
		*total = 0;
	if (avail)
		*avail = 0;

	/* the first call reports the size needed. allocating a buffer to
	 * hold the map changes the map, so ask for slack rather than the
	 * exact figure and risk a second EFI_BUFFER_TOO_SMALL.
	 */
	if (BS->GetMemoryMap(&size, 0, &mapkey, &dsize, &dver) !=
	    EFI_BUFFER_TOO_SMALL || size == 0 || dsize == 0)
		return;
	size += 8 * dsize;
	if (BS->AllocatePool(EfiLoaderData, size, (void **)&map) !=
	    EFI_SUCCESS)
		return;
	if (BS->GetMemoryMap(&size, map, &mapkey, &dsize, &dver) !=
	    EFI_SUCCESS) {
		BS->FreePool(map);
		return;
	}

	for (UINTN off = 0; off + dsize <= size; off += dsize) {
		EFI_MEMORY_DESCRIPTOR *d =
		    (EFI_MEMORY_DESCRIPTOR *)((char *)map + off);
		unsigned long long bytes = d->NumberOfPages * 4096ULL;

		switch (d->Type) {
		case EfiConventionalMemory:
			a += bytes;
			t += bytes;
			break;
		case EfiLoaderCode:
		case EfiLoaderData:
		case EfiBootServicesCode:
		case EfiBootServicesData:
		case EfiRuntimeServicesCode:
		case EfiRuntimeServicesData:
		case EfiACPIReclaimMemory:
			t += bytes;
			break;
		default:
			break;
		}
	}
	BS->FreePool(map);
	if (total)
		*total = t;
	if (avail)
		*avail = a;
}

/* one kind of memory here, so the lua heap's chunks are ordinary
 * allocations. See platform.h: the hook exists for the esp32, which has
 * two and must be told which.
 */
void *platform_chunk_alloc(size_t n);
void platform_chunk_free(void *p, size_t n);

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
