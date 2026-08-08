#ifndef LUAHEAP_H
#define LUAHEAP_H

/* a heap for one lua_State.
 *
 * This exists because lua's allocator interface gives us something a
 * general malloc never has: the true size of a block on every free and
 * every realloc. lua_Alloc(ud, ptr, osize, nsize) carries osize
 * whenever ptr is non-null. So a block needs no header -- nothing has
 * to be stored to answer a question we are always told the answer to.
 *
 * Two other things are true here and not of malloc generally: a VM's
 * memory all dies at once when its proc exits, so teardown can drop
 * whole chunks instead of walking objects; and scheduling is
 * cooperative with one heap per proc, so there is nothing to lock.
 *
 * Blocks up to LUAHEAP_MAXSMALL come from per-class free lists carved
 * out of large chunks, so the underlying allocator's own per-call
 * overhead is paid once per chunk rather than once per object. Bigger
 * blocks go straight to the chunk source, which is what the previous
 * arrangement did for everything.
 */

#include <stddef.h>

#define LUAHEAP_MAXSMALL 512

/* where chunks come from. The kernel plugs in AllocatePool; the host
 * tests plug in malloc, which is the whole point of the split -- this
 * file is exercised natively, without a VM or firmware anywhere.
 */
struct luaheap_ops {
	void	*(*chunk_alloc)(void *ud, size_t n);
	void	 (*chunk_free)(void *ud, void *p, size_t n);
};

struct luaheap_stats {
	size_t	live;		/* bytes handed out, as lua counts them */
	size_t	peak;		/* high water mark of live */
	size_t	mapped;		/* bytes taken from the chunk source */
	size_t	waste;		/* mapped - live, the overhead this is for */
	unsigned long chunks;
	unsigned long larges;

	/* where the waste is, since "no header" is only true of the
	 * small path and the rest is worth being able to see:
	 *   rounding  live blocks' class size, less what lua asked for
	 *   headers   struct large per big block, struct chunk per chunk
	 *   unused    mapped bytes never handed out -- the tail of the
	 *             current chunk, plus what earlier chunks abandoned
	 * The three sum to waste.
	 */
	size_t	rounding;
	size_t	headers;
	size_t	unused;

	/* part of unused, and the part that can be had back at once: large
	 * blocks lua freed and this heap kept against the next request of
	 * the same size. The rest of unused is free space inside chunks
	 * still in use, which only a compacting heap could recover.
	 */
	size_t	cached;
};

struct luaheap;

struct luaheap *luaheap_new(const struct luaheap_ops *ops, void *ud);

/* free every chunk at once. This is the operation proc teardown wants:
 * it does not walk live objects and does not care what order the GC
 * would have collected them in.
 */
void	luaheap_destroy(struct luaheap *h);

/* lua_Alloc's contract, minus lua's type-tag convention: callers pass
 * osize as 0 when ptr is null, never a type tag. Returns null on
 * failure for nsize > 0, and always null for nsize == 0.
 */
void	*luaheap_realloc(struct luaheap *h, void *ptr, size_t osize,
	    size_t nsize);

/* Hand back every chunk nothing is using, and report the bytes. Runs
 * when memory is short or when a proc has just exited and dropped its
 * working set -- not on a schedule, because the walk is proportional to
 * the free lists and there is nothing to find most of the time.
 */
size_t	luaheap_reclaim(struct luaheap *h);

/* the same, plus the large cache, and report the bytes. This is what
 * the heap can give back to the machine when asked rather than when it
 * runs out: reclaim alone leaves the cache held.
 */
size_t	luaheap_release(struct luaheap *h);

void	luaheap_stats(const struct luaheap *h, struct luaheap_stats *out);

#endif
