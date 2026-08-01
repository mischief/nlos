/* see luaheap.h for why this can be headerless. */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "luaheap.h"

/* lua's own alignment requirement is LUAI_MAXALIGN, which is the widest
 * of lua_Number, double, void *, lua_Integer and long -- 8 on every
 * target we build for. Every size class below is a multiple of it.
 */
#define ALIGN 8

/* Spacing is finer below 128 because that is where lua actually lives:
 * measured on a booted proc, the mean live object is ~68 bytes across
 * ~570 live allocations. Classes past that exist to keep the large-block
 * path rare rather than to be packed tightly.
 */
static const size_t classes[] = {
	16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512,
};

#define NCLASS (sizeof classes / sizeof classes[0])

/* One chunk backs many small blocks. 64K keeps the chunk source's own
 * per-call cost -- 92 bytes per AllocatePool call, measured -- down to
 * a fraction of a byte per object.
 */
#define CHUNK_BYTES (64 * 1024)

struct chunk {
	struct chunk *next;
	size_t size;
};

/* A large block is the one thing here that carries a header, because
 * destroy has to find it and the chunk source has to be told the size
 * it was given. Large blocks are the geometric tail of array growth:
 * rare, and already paying this cost today.
 */
struct large {
	struct large *next;
	size_t size;		/* as passed to chunk_alloc */
};

struct luaheap {
	const struct luaheap_ops *ops;
	void *ud;

	struct chunk *chunks;
	struct large *larges;

	/* the current chunk's unhanded-out tail */
	char *bump;
	size_t bumpleft;

	/* free lists thread through the free blocks themselves, so a
	 * free block costs nothing either. A block is only ever on the
	 * list for the class it was allocated from.
	 */
	void *freelist[NCLASS];

	size_t live, peak, mapped;
	unsigned long nchunks, nlarges;
};

/* the smallest class that fits, or NCLASS for the large path.
 *
 * A linear scan beats anything cleverer here: the array is 11 entries
 * in one cache line, and the common sizes are at the front.
 */
static size_t
classof(size_t n)
{
	for (size_t i = 0; i < NCLASS; i++) {
		if (n <= classes[i])
			return i;
	}
	return NCLASS;
}

static size_t
roundup(size_t n, size_t a)
{
	return (n + a - 1) & ~(a - 1);
}

struct luaheap *
luaheap_new(const struct luaheap_ops *ops, void *ud)
{
	struct luaheap *h;

	if (!ops || !ops->chunk_alloc || !ops->chunk_free)
		return 0;

	h = ops->chunk_alloc(ud, sizeof *h);
	if (!h)
		return 0;
	memset(h, 0, sizeof *h);
	h->ops = ops;
	h->ud = ud;
	return h;
}

void
luaheap_destroy(struct luaheap *h)
{
	if (!h)
		return;

	/* order matters only in that the heap itself goes last: it holds
	 * the list heads and the ops used to free everything else.
	 */
	for (struct large *l = h->larges; l;) {
		struct large *next = l->next;

		h->ops->chunk_free(h->ud, l, l->size);
		l = next;
	}
	for (struct chunk *c = h->chunks; c;) {
		struct chunk *next = c->next;

		h->ops->chunk_free(h->ud, c, c->size);
		c = next;
	}

	const struct luaheap_ops *ops = h->ops;
	void *ud = h->ud;

	ops->chunk_free(ud, h, sizeof *h);
}

/* take a fresh chunk and make it the bump region.
 *
 * whatever is left of the old one is abandoned rather than tracked. It
 * is under one class width by construction -- we only get here when the
 * request did not fit -- so the loss is bounded by the largest class,
 * once per 64K chunk.
 */
static int
newchunk(struct luaheap *h, size_t need)
{
	size_t want = CHUNK_BYTES;
	struct chunk *c;

	if (need + sizeof *c > want)
		want = roundup(need + sizeof *c, ALIGN);

	c = h->ops->chunk_alloc(h->ud, want);
	if (!c)
		return 0;
	c->size = want;
	c->next = h->chunks;
	h->chunks = c;

	h->bump = (char *)c + sizeof *c;
	h->bumpleft = want - sizeof *c;
	h->mapped += want;
	h->nchunks++;
	return 1;
}

static void *
small_alloc(struct luaheap *h, size_t ci)
{
	size_t want = classes[ci];
	void *p = h->freelist[ci];

	if (p) {
		/* the link lives in the free block's own first word */
		h->freelist[ci] = *(void **)p;
		return p;
	}
	if (h->bumpleft < want && !newchunk(h, want))
		return 0;

	p = h->bump;
	h->bump += want;
	h->bumpleft -= want;
	return p;
}

static void *
large_alloc(struct luaheap *h, size_t n)
{
	size_t want = roundup(n + sizeof(struct large), ALIGN);
	struct large *l = h->ops->chunk_alloc(h->ud, want);

	if (!l)
		return 0;
	l->size = want;
	l->next = h->larges;
	h->larges = l;
	h->mapped += want;
	h->nlarges++;
	return (char *)l + sizeof *l;
}

static void
large_free(struct luaheap *h, void *ptr)
{
	struct large *l = (struct large *)((char *)ptr - sizeof(struct large));
	struct large **pp = &h->larges;

	while (*pp && *pp != l)
		pp = &(*pp)->next;
	if (!*pp)
		return;		/* not ours; caller lied about the size */
	*pp = l->next;
	h->mapped -= l->size;
	h->nlarges--;
	h->ops->chunk_free(h->ud, l, l->size);
}

void *
luaheap_realloc(struct luaheap *h, void *ptr, size_t osize, size_t nsize)
{
	size_t oc, nc;

	if (!h)
		return 0;

	if (nsize == 0) {
		if (ptr) {
			oc = classof(osize);
			if (oc < NCLASS) {
				*(void **)ptr = h->freelist[oc];
				h->freelist[oc] = ptr;
			} else {
				large_free(h, ptr);
			}
			h->live -= osize;
		}
		return 0;
	}

	if (!ptr) {
		void *p;

		nc = classof(nsize);
		p = nc < NCLASS ? small_alloc(h, nc) : large_alloc(h, nsize);
		if (!p)
			return 0;
		h->live += nsize;
		if (h->live > h->peak)
			h->peak = h->live;
		return p;
	}

	oc = classof(osize);
	nc = classof(nsize);

	/* the case worth having: growing or shrinking inside one class is
	 * free. lua's string buffers and table arrays step through sizes
	 * far more often than they cross a class boundary, and every one
	 * of those steps is a malloc+memcpy+free today.
	 */
	if (oc == nc && oc < NCLASS) {
		h->live += nsize - osize;
		if (h->live > h->peak)
			h->peak = h->live;
		return ptr;
	}

	void *q = nc < NCLASS ? small_alloc(h, nc) : large_alloc(h, nsize);

	if (!q)
		return 0;
	memcpy(q, ptr, osize < nsize ? osize : nsize);

	if (oc < NCLASS) {
		*(void **)ptr = h->freelist[oc];
		h->freelist[oc] = ptr;
	} else {
		large_free(h, ptr);
	}

	h->live += nsize - osize;
	if (h->live > h->peak)
		h->peak = h->live;
	return q;
}

void
luaheap_stats(const struct luaheap *h, struct luaheap_stats *out)
{
	if (!h || !out)
		return;
	out->live = h->live;
	out->peak = h->peak;
	out->mapped = h->mapped;
	out->waste = h->mapped > h->live ? h->mapped - h->live : 0;
	out->chunks = h->nchunks;
	out->larges = h->nlarges;
}
