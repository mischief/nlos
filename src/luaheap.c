/* see luaheap.h for why this can be headerless. */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* the platform's param.h sets the scale where there is one. The host
 * bench and unit test link this file with no platform at all, so the
 * defaults below stand in for them.
 */
#if defined(__has_include)
#if __has_include("param.h")
#include "param.h"
#endif
#endif

#include "luaheap.h"

/* lua's own alignment requirement is LUAI_MAXALIGN, which is the widest
 * of lua_Number, double, void *, lua_Integer and long -- 8 on every
 * target we build for. Every size class below is a multiple of it.
 */
#define ALIGN 8

/* Chosen from the measured request profile, not from a size-doubling
 * habit. test/luaheap_bench.c counts what lua actually asks for: of
 * 14430 requests in a representative workload, seven sizes are 95% of
 * them -- 29, 56, 48, 34, 28, 33 and 40 bytes -- and only 36 requests
 * exceeded 1024 bytes. Those are lua's own structures and short string
 * headers, so the shape holds across workloads even where the counts
 * do not.
 *
 * Hence 8-byte spacing all the way to 64, which is where nearly
 * everything lands. Coarse doubling above it, since requests there are
 * rare enough that the rounding costs less than the extra free lists
 * would. Every class must stay a multiple of ALIGN: a class is the
 * stride between consecutive blocks in a chunk, so a class of 28 would
 * hand out misaligned pointers.
 *
 * Rounding is worth this attention because it is where the waste is:
 * 90457 bytes of 108145 in that same run, against 352 bytes of headers.
 */
static const size_t classes[] = {
	16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 192, 256, 384, 512,
};

#define NCLASS (sizeof classes / sizeof classes[0])

/* One chunk backs many small blocks, which is how the chunk source's
 * own per-call cost -- 92 bytes per AllocatePool call, measured -- stops
 * falling on every object.
 *
 * Sized against what the heap actually holds rather than against that
 * per-call cost, because the tail of the last chunk is pure loss. At 64K
 * chunks a single 39K proc took one chunk and wasted two thirds of it,
 * measured 2.05x overhead against lua's own view.
 *
 * Slightly UNDER 8K, not 8K: the chunk header lives inside the chunk,
 * but the chunk source's own does not. On efi that is malloc's 16 bytes
 * plus the firmware pool's metadata, and at exactly 8192 the total
 * spills into a third page -- 73898 bytes per proc against 57514 for
 * this size, back when each proc had its own heap. The 128 is slack for
 * headers we do not control rather than a tuned figure.
 */
#ifndef LUAHEAP_CHUNK
#define LUAHEAP_CHUNK (8 * 1024)
#endif
#ifndef LUAHEAP_LARGE_CACHED
#define LUAHEAP_LARGE_CACHED 4
#endif

#define CHUNK_BYTES (LUAHEAP_CHUNK - 128)

struct chunk {
	struct chunk *next;
	size_t size;
};

/* A large block is the one thing here that carries a header, because
 * destroy has to find it and the chunk source has to be told the size
 * it was given.
 */
struct large {
	struct large *next;
	size_t size;		/* as passed to chunk_alloc */
};

/* Large blocks were assumed to be the geometric tail of array growth --
 * rare, and so worth no more than a straight pass to the chunk source.
 * That is true of lua's own objects, which is why the classes above
 * stop at 512. It is not true of a payload arriving over a port: that
 * is a lua string of whatever the message carried, 4K and 8K for 9p,
 * whose msize is 8192. Measured at 4 allocations per 4K message round
 * trip, and this was one of them.
 *
 * So a freed large block is cached by size rather than handed back. The
 * granularity is uniform rather than doubling, because doubling is far
 * too coarse here: a 4K string plus its lua header and this one asks
 * for a little over 4096, which a power-of-two class would round to
 * 8192 and waste nearly half of. At 512 the rounding waste is bounded
 * by 511 bytes, and repeated requests for one size still land in one
 * bucket, which is the whole point.
 *
 * Capped per class, because a cache that never evicts is a leak with
 * better manners: freeing a thousand 4K blocks at once should not hold
 * 4M forever against the chance that a thousand more are coming.
 */
#define LARGE_GRAIN   512
#define LARGE_MAXSIZE (64 * 1024)	/* kernel.c's MAXMSG; above, don't cache */
#define NLARGECLASS   (LARGE_MAXSIZE / LARGE_GRAIN)
#define LARGE_CACHED  LUAHEAP_LARGE_CACHED

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

	/* freed large blocks, kept rather than returned, threaded through
	 * the blocks' own payload the way freelist[] is. A cached block
	 * stays on h->larges too, so destroy still finds it and mapped
	 * still counts it -- it is held, not gone.
	 */
	void *largefree[NLARGECLASS];
	unsigned char nlargefree[NLARGECLASS];

	size_t live, peak, mapped;
	unsigned long nchunks, nlarges;

	/* sum of the class sizes of live small blocks, and of what lua
	 * asked for in live large ones, so the rounding cost can be told
	 * apart from chunk tails when reporting
	 */
	size_t rounded, large_asked;
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

/* the bucket a block of exactly `want` bytes belongs to, or NLARGECLASS
 * for one too big to cache. `want` is always a multiple of LARGE_GRAIN
 * when it came from large_want() below, so this is exact rather than a
 * nearest-fit search.
 */
static size_t
largeclassof(size_t want)
{
	if (want == 0 || want > LARGE_MAXSIZE || want % LARGE_GRAIN)
		return NLARGECLASS;
	return want / LARGE_GRAIN - 1;
}

/* what to actually ask the chunk source for, so that a block returned
 * to a bucket can serve any later request that maps to the same one.
 */
static size_t
large_want(size_t need)
{
	if (need > LARGE_MAXSIZE)
		return roundup(need, ALIGN);
	return roundup(need, LARGE_GRAIN);
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
	h->mapped = sizeof *h;	/* the heap is part of what the heap costs */
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

/* carve whatever is left of the current bump region into free blocks
 * rather than abandoning it.
 *
 * The remainder is under one class width only in the sense that the
 * request that triggered a new chunk did not fit -- against a 512-byte
 * class it can be almost 512 bytes, which at an 8K chunk would be 6%
 * given away per chunk. Cutting it into the largest classes that fit
 * gives nearly all of it back, and the blocks are indistinguishable
 * from any other free block of their class.
 */
static void
drain_bump(struct luaheap *h)
{
	size_t ci = NCLASS;

	while (h->bumpleft >= classes[0]) {
		/* largest class that still fits */
		while (ci > 0 && classes[ci - 1] > h->bumpleft)
			ci--;
		if (ci == 0)
			break;

		void *p = h->bump;

		h->bump += classes[ci - 1];
		h->bumpleft -= classes[ci - 1];
		*(void **)p = h->freelist[ci - 1];
		h->freelist[ci - 1] = p;
	}
	h->bumpleft = 0;
}

static size_t release_largefree(struct luaheap *h);

/* take a fresh chunk and make it the bump region. */
static int
newchunk(struct luaheap *h, size_t need)
{
	size_t want = CHUNK_BYTES;
	struct chunk *c;

	if (need + sizeof *c > want)
		want = roundup(need + sizeof *c, ALIGN);

	c = h->ops->chunk_alloc(h->ud, want);
	if (!c && release_largefree(h))
		c = h->ops->chunk_alloc(h->ud, want);
	if (!c)
		return 0;
	c->size = want;
	c->next = h->chunks;
	h->chunks = c;

	/* only once the replacement is secured: on failure the caller can
	 * still be served from the region we would otherwise have cut up
	 */
	drain_bump(h);

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
		h->rounded += want;
		return p;
	}
	if (h->bumpleft < want && !newchunk(h, want))
		return 0;

	p = h->bump;
	h->bump += want;
	h->bumpleft -= want;
	h->rounded += want;
	return p;
}

static void
small_free(struct luaheap *h, void *ptr, size_t ci)
{
	*(void **)ptr = h->freelist[ci];
	h->freelist[ci] = ptr;
	h->rounded -= classes[ci];
}

static void *
large_alloc(struct luaheap *h, size_t n)
{
	size_t want = large_want(n + sizeof(struct large));
	size_t ci = largeclassof(want);
	struct large *l;

	/* a cached block of this bucket is already the right size and
	 * already on h->larges, so taking one back is a pop and nothing
	 * else -- no chunk_alloc, and no change to mapped
	 */
	if (ci < NLARGECLASS && h->largefree[ci]) {
		void *p = h->largefree[ci];

		h->largefree[ci] = *(void **)p;
		h->nlargefree[ci]--;
		h->nlarges++;
		h->large_asked += n;
		return p;
	}

	l = h->ops->chunk_alloc(h->ud, want);
	if (!l && release_largefree(h))
		l = h->ops->chunk_alloc(h->ud, want);
	if (!l)
		return 0;
	l->size = want;
	l->next = h->larges;
	h->larges = l;
	h->mapped += want;
	h->nlarges++;
	h->large_asked += n;
	return (char *)l + sizeof *l;
}

/* hand every cached large block back to the chunk source.
 *
 * The cache in largefree exists so a repeated request of one size does
 * not go back to the allocator, and on a machine with room that is a
 * clear win. On one without, it is memory the rest of the system cannot
 * see: measured on an esp32 with 386KB total as 113KB unused inside the
 * heap while malloc had 32KB left, which is a proc dying of "not enough
 * memory" beside a heap holding a third of the machine.
 *
 * Sizing the cache per platform (LUAHEAP_LARGE_CACHED) is the standing
 * fix; this is the pressure valve for the peak that tuning cannot see
 * coming, called when the chunk source says no rather than on a
 * schedule. Removing it and re-measuring puts the screenshot back to
 * dying of "not enough memory", so this path is required rather than
 * insurance. Returns bytes released, so a caller can tell whether
 * retrying is worth anything.
 */
static size_t
release_largefree(struct luaheap *h)
{
	size_t freed = 0;

	for (size_t ci = 0; ci < NLARGECLASS; ci++) {
		while (h->largefree[ci]) {
			void *ptr = h->largefree[ci];
			struct large *l = (struct large *)((char *)ptr -
			    sizeof(struct large));
			struct large **pp = &h->larges;

			h->largefree[ci] = *(void **)ptr;
			h->nlargefree[ci]--;

			/* a cached block kept its place on h->larges, so
			 * releasing it for real means unlinking it here.
			 */
			while (*pp && *pp != l)
				pp = &(*pp)->next;
			if (!*pp)
				continue;
			*pp = l->next;
			h->mapped -= l->size;
			freed += l->size;
			h->ops->chunk_free(h->ud, l, l->size);
		}
	}
	return freed;
}

static void
large_free(struct luaheap *h, void *ptr, size_t asked)
{
	struct large *l = (struct large *)((char *)ptr - sizeof(struct large));
	size_t ci = largeclassof(l->size);
	struct large **pp;

	h->large_asked -= asked < h->large_asked ? asked : h->large_asked;

	/* the common case: hold it for the next request of its size. The
	 * block keeps its place on h->larges, so this walks nothing.
	 */
	if (ci < NLARGECLASS && h->nlargefree[ci] < LARGE_CACHED) {
		*(void **)ptr = h->largefree[ci];
		h->largefree[ci] = ptr;
		h->nlargefree[ci]++;
		h->nlarges--;
		return;
	}

	/* over the cap, or too big to bucket: give it back, which is the
	 * only path that has to find the block on h->larges
	 */
	pp = &h->larges;
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
			if (oc < NCLASS)
				small_free(h, ptr, oc);
			else
				large_free(h, ptr, osize);
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

	/* the same, one size up: a large block that still lands in its own
	 * bucket does not need to move either. classof cannot see this --
	 * it answers NCLASS for every large, so oc == nc above would be
	 * true of two sizes megabytes apart -- which is why the test is on
	 * the block's actual size rather than on the class index.
	 */
	if (oc >= NCLASS && nc >= NCLASS) {
		struct large *l =
		    (struct large *)((char *)ptr - sizeof(struct large));

		if (large_want(nsize + sizeof *l) == l->size) {
			h->large_asked += nsize - osize;
			h->live += nsize - osize;
			if (h->live > h->peak)
				h->peak = h->live;
			return ptr;
		}
	}

	void *q = nc < NCLASS ? small_alloc(h, nc) : large_alloc(h, nsize);

	if (!q)
		return 0;
	memcpy(q, ptr, osize < nsize ? osize : nsize);

	if (oc < NCLASS)
		small_free(h, ptr, oc);
	else
		large_free(h, ptr, osize);

	h->live += nsize - osize;
	if (h->live > h->peak)
		h->peak = h->live;
	return q;
}

void
luaheap_stats(const struct luaheap *h, struct luaheap_stats *out)
{
	if (!out)
		return;

	/* zeroed rather than left alone for a null heap: a dead proc has
	 * no heap, and callers report these figures straight out.
	 */
	memset(out, 0, sizeof *out);
	if (!h)
		return;

	out->live = h->live;
	out->peak = h->peak;
	out->mapped = h->mapped;
	out->waste = h->mapped > h->live ? h->mapped - h->live : 0;
	out->chunks = h->nchunks;
	out->larges = h->nlarges;

	/* small blocks carry nothing, so the only headers are one per
	 * chunk and one per outstanding large block.
	 */
	out->headers = h->nchunks * sizeof(struct chunk) +
	    h->nlarges * sizeof(struct large);

	/* h->rounded counts live small blocks at their class size, so the
	 * difference from what lua asked for in those same blocks is the
	 * rounding cost. Large blocks are excluded from both sides: they
	 * are not rounded to a class, and their header is counted above.
	 */
	size_t small_asked = h->live > h->large_asked ?
	    h->live - h->large_asked : 0;

	out->rounding = h->rounded > small_asked ? h->rounded - small_asked : 0;
	out->unused = out->waste > out->rounding + out->headers ?
	    out->waste - out->rounding - out->headers : 0;
}
