/* what src/buf.c needs from the kernel, for the host tests.
 *
 * lib/ files are run under the host's own lua5.4 by test/host_*.lua, so
 * a module in lib/ that requires los.buf needs one there. Building the
 * real src/buf.c against these is what keeps the host and the guest
 * testing the same implementation rather than a double that drifts.
 *
 * Storage is malloc rather than the chunk source, and the accounting is
 * a no-op: there are no procs here to charge, and what the host tests
 * are checking is the bytes.
 */

#include <stdlib.h>

#include "buf.h"

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

int
kbuf_charge(lua_State *L, size_t n)
{
	(void)L;
	(void)n;
	return 1;
}

void
kbuf_uncharge(lua_State *L, size_t n)
{
	(void)L;
	(void)n;
}

size_t
kbuf_pooled(void)
{
	return 0;
}

/* the guest counts this per proc; here one counter serves the one
 * state a host test runs in.
 */
int
kbuf_step_due(lua_State *L, size_t n)
{
	static size_t debt;

	(void)L;
	debt += n;
	if (debt < 64 * 1024)
		return 0;
	debt = 0;
	return 1;
}
