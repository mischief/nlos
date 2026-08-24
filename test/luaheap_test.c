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

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "luaheap.h"
#include "tap.h"

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

/* The heap the scenarios below share. They run in registration order:
 * create makes it, teardown destroys it, and each one in between leaves
 * it usable for the next.
 */
struct ctx {
	struct luaheap *h;
};

static int
test_create(void *arg)
{
	struct ctx *c = arg;

	c->h = luaheap_new(&host_ops, 0);
	TAP_CHECK(c->h != 0, "a heap can be created");
	return c->h == 0;
}

static int
test_classes(void *arg)
{
	struct ctx *c = arg;
	void *a = luaheap_realloc(c->h, 0, 0, 32);
	void *b = luaheap_realloc(c->h, 0, 0, 32);

	TAP_CHECK(a && b && a != b, "two allocations of one class are distinct");
	TAP_CHECK(((uintptr_t)a % 8) == 0 && ((uintptr_t)b % 8) == 0,
	    "allocations are 8-byte aligned");

	memset(a, 0xaa, 32);
	memset(b, 0xbb, 32);
	TAP_CHECK(*(unsigned char *)a == 0xaa && *(unsigned char *)b == 0xbb,
	    "the two do not alias");

	/* a freed block should come back rather than growing the heap */
	luaheap_realloc(c->h, b, 32, 0);
	TAP_CHECK(luaheap_realloc(c->h, 0, 0, 32) == b,
	    "a freed block is reused by its own class");
	return 0;
}

static int
test_grow(void *arg)
{
	struct ctx *c = arg;
	int kept = 1;

	/* growth inside one class must not move, which is the case this
	 * design exists to make free
	 */
	void *d = luaheap_realloc(c->h, 0, 0, 20);
	void *e = luaheap_realloc(c->h, d, 20, 24);

	TAP_CHECK(d == e, "growing within a class returns the same pointer");

	/* crossing a class must move and must preserve contents */
	memset(e, 0x5a, 24);

	void *f = luaheap_realloc(c->h, e, 24, 300);

	for (int i = 0; i < 24; i++) {
		if (((unsigned char *)f)[i] != 0x5a)
			kept = 0;
	}
	TAP_CHECK(f != 0 && kept, "crossing a class preserves the old contents");
	return 0;
}

static int
test_large(void *arg)
{
	struct ctx *c = arg;
	int keptbig = 1;

	/* the large path */
	void *g = luaheap_realloc(c->h, 0, 0, 40000);

	TAP_CHECK(g != 0, "a block past the largest class is served");
	memset(g, 0x77, 40000);

	void *g2 = luaheap_realloc(c->h, g, 40000, 80000);

	for (int i = 0; i < 40000; i++) {
		if (((unsigned char *)g2)[i] != 0x77)
			keptbig = 0;
	}
	TAP_CHECK(g2 != 0 && keptbig, "a large block survives being grown");
	luaheap_realloc(c->h, g2, 80000, 0);
	return 0;
}

static int
test_torture(void *arg)
{
	struct ctx *c = arg;
	struct luaheap *h = c->h;
	int bad_overlap = 0, bad_content = 0;

	nlive = 0;

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

	tap_diag("torture: %d blocks still live", nlive);
	TAP_CHECK(bad_overlap == 0, "no allocation ever overlapped a live block");
	TAP_CHECK(bad_content == 0, "no block's contents were ever corrupted");
	return 0;
}

static int
test_teardown(void *arg)
{
	struct ctx *c = arg;
	size_t before = host_live;

	luaheap_destroy(c->h);
	c->h = 0;
	tap_diag("chunk source held %zu bytes before destroy, %zu after",
	    before, host_live);
	TAP_CHECK(host_live == 0,
	    "destroy returns every byte, without walking live objects");
	return 0;
}

int
main(void)
{
	static struct ctx c;

	TAP_ADD("create", test_create, &c);
	TAP_ADD("size classes", test_classes, &c);
	TAP_ADD("growing", test_grow, &c);
	TAP_ADD("large blocks", test_large, &c);
	TAP_ADD("torture", test_torture, &c);
	TAP_ADD("teardown", test_teardown, &c);
	return tap_run();
}
