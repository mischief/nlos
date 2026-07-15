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
