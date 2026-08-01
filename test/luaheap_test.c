/* luaheap in isolation: no VM, no firmware, host malloc as the chunk
 * source. Emits TAP.
 *
 * The interesting property to attack is that luaheap trusts the caller
 * to report osize honestly, since that is what lets it skip headers. So
 * the torture below keeps a shadow model of every live block and its
 * expected contents, and verifies that nothing the allocator hands back
 * ever overlaps something already live -- which is the shape a
 * size-class or free-list bug takes.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "luaheap.h"

static int count, failed;

static int
ok(int cond, const char *name)
{
	count++;
	if (!cond)
		failed++;
	printf("%s %d - %s\n", cond ? "ok" : "not ok", count, name);
	fflush(stdout);
	return cond;
}

static void
diag(const char *fmt, ...)
{
	va_list ap;

	fputs("# ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
	fflush(stdout);
}

/* ---- chunk source: plain malloc, with accounting ---- */

static size_t host_live, host_calls;

static void *
host_alloc(void *ud, size_t n)
{
	(void)ud;
	host_live += n;
	host_calls++;
	return malloc(n);
}

static void
host_free(void *ud, void *p, size_t n)
{
	(void)ud;
	host_live -= n;
	free(p);
}

static const struct luaheap_ops host_ops = {
	.chunk_alloc = host_alloc,
	.chunk_free = host_free,
};

/* ---- shadow model ---- */

#define MAXLIVE 4096

struct blk {
	void *p;
	size_t n;
	unsigned char seed;
};

static struct blk live[MAXLIVE];
static int nlive;

static void
fill(struct blk *b)
{
	unsigned char *q = b->p;

	for (size_t i = 0; i < b->n; i++)
		q[i] = (unsigned char)(b->seed + (i & 0xff));
}

static int
check(const struct blk *b)
{
	const unsigned char *q = b->p;

	for (size_t i = 0; i < b->n; i++) {
		if (q[i] != (unsigned char)(b->seed + (i & 0xff)))
			return 0;
	}
	return 1;
}

/* does [p, p+n) touch any live block other than self? */
static int
overlaps(void *p, size_t n, int self)
{
	char *a = p, *ae = a + n;

	for (int i = 0; i < nlive; i++) {
		if (i == self)
			continue;

		char *b = live[i].p, *be = b + live[i].n;

		if (a < be && b < ae)
			return 1;
	}
	return 0;
}

static unsigned long rngstate = 12345;

static unsigned long
rnd(void)
{
	/* xorshift, so the sequence is identical everywhere this runs */
	rngstate ^= rngstate << 13;
	rngstate ^= rngstate >> 7;
	rngstate ^= rngstate << 17;
	return rngstate;
}

static size_t
rndsize(void)
{
	/* weighted towards the small sizes lua actually allocates, with a
	 * tail that crosses into the large path
	 */
	switch (rnd() % 10) {
	case 0:
		return 1 + rnd() % 16;
	case 1:
	case 2:
	case 3:
		return 1 + rnd() % 64;
	case 4:
	case 5:
	case 6:
		return 1 + rnd() % 200;
	case 7:
	case 8:
		return 1 + rnd() % 512;
	default:
		return 1 + rnd() % 8000;
	}
}

int
main(void)
{
	printf("1..12\n");

	/* ---- basics ---- */
	struct luaheap *h = luaheap_new(&host_ops, 0);

	ok(h != 0, "a heap can be created");

	void *a = luaheap_realloc(h, 0, 0, 32);
	void *b = luaheap_realloc(h, 0, 0, 32);

	ok(a && b && a != b, "two allocations of one class are distinct");
	ok(((uintptr_t)a % 8) == 0 && ((uintptr_t)b % 8) == 0,
	    "allocations are 8-byte aligned");

	memset(a, 0xaa, 32);
	memset(b, 0xbb, 32);
	ok(*(unsigned char *)a == 0xaa && *(unsigned char *)b == 0xbb,
	    "the two do not alias");

	/* a freed block should come back rather than growing the heap */
	luaheap_realloc(h, b, 32, 0);

	void *c = luaheap_realloc(h, 0, 0, 32);

	ok(c == b, "a freed block is reused by its own class");

	/* growth inside one class must not move, which is the case this
	 * design exists to make free
	 */
	void *d = luaheap_realloc(h, 0, 0, 20);
	void *e = luaheap_realloc(h, d, 20, 24);

	ok(d == e, "growing within a class returns the same pointer");

	/* crossing a class must move and must preserve contents */
	memset(e, 0x5a, 24);

	void *f = luaheap_realloc(h, e, 24, 300);
	int kept = 1;

	for (int i = 0; i < 24; i++) {
		if (((unsigned char *)f)[i] != 0x5a)
			kept = 0;
	}
	ok(f != 0 && kept, "crossing a class preserves the old contents");

	/* the large path */
	void *g = luaheap_realloc(h, 0, 0, 40000);

	ok(g != 0, "a block past the largest class is served");
	memset(g, 0x77, 40000);

	void *g2 = luaheap_realloc(h, g, 40000, 80000);
	int keptbig = 1;

	for (int i = 0; i < 40000; i++) {
		if (((unsigned char *)g2)[i] != 0x77)
			keptbig = 0;
	}
	ok(g2 != 0 && keptbig, "a large block survives being grown");
	luaheap_realloc(h, g2, 80000, 0);

	/* ---- torture ---- */
	nlive = 0;
	int bad_overlap = 0, bad_content = 0;

	for (long step = 0; step < 200000; step++) {
		int op = rnd() % 100;

		if (nlive < MAXLIVE && (op < 45 || nlive == 0)) {
			size_t n = rndsize();
			void *p = luaheap_realloc(h, 0, 0, n);

			if (!p)
				continue;
			if (overlaps(p, n, -1))
				bad_overlap++;

			live[nlive].p = p;
			live[nlive].n = n;
			live[nlive].seed = (unsigned char)(rnd() & 0xff);
			fill(&live[nlive]);
			nlive++;
		} else if (op < 75) {
			int i = (int)(rnd() % (unsigned long)nlive);

			if (!check(&live[i]))
				bad_content++;
			luaheap_realloc(h, live[i].p, live[i].n, 0);
			live[i] = live[nlive - 1];
			nlive--;
		} else {
			int i = (int)(rnd() % (unsigned long)nlive);
			size_t n = rndsize();

			if (!check(&live[i]))
				bad_content++;

			size_t keep = live[i].n < n ? live[i].n : n;
			unsigned char seed = live[i].seed;
			void *p = luaheap_realloc(h, live[i].p, live[i].n, n);

			if (!p)
				continue;

			/* only the surviving prefix is guaranteed */
			const unsigned char *q = p;

			for (size_t k = 0; k < keep; k++) {
				if (q[k] != (unsigned char)(seed + (k & 0xff)))
					bad_content++;
			}

			live[i].p = p;
			live[i].n = n;
			live[i].seed = seed;
			fill(&live[i]);

			if (overlaps(p, n, i))
				bad_overlap++;
		}
	}

	diag("torture: %d blocks still live", nlive);
	ok(bad_overlap == 0, "no allocation ever overlapped a live block");
	ok(bad_content == 0, "no block's contents were ever corrupted");

	/* ---- teardown frees everything ---- */
	size_t before = host_live;

	luaheap_destroy(h);
	diag("chunk source held %zu bytes before destroy, %zu after",
	    before, host_live);
	ok(host_live == 0,
	    "destroy returns every byte, without walking live objects");

	return failed ? 1 : 0;
}
