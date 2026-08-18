/* per-platform kernel table sizes: headroom, not reachable counts. See
 * kernel.c for what they cost. A process gets as much address space as
 * it asks for, so nothing here is the constraint, and matching the
 * other machines keeps the shared boot tests comparing like with like.
 */
#define MAXPROCS	4096
#define MAXPORTS	32768

/* luaheap's granularity: memory held against allocations avoided. */
#define LUAHEAP_CHUNK		(8 * 1024)
#define LUAHEAP_LARGE_CACHED	4

/* Lua's gc pause, as a percentage of live. */
#define GCPAUSE		200
