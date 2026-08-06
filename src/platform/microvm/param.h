/* per-platform kernel table sizes. see kernel.c for what they cost and
 * why they are headroom rather than reachable counts.
 *
 * same as efi: a vm is told how much memory it has and it is never this
 * tight. keeping the two identical also keeps the boot tests comparing
 * like with like across the platforms that share them.
 */
#define MAXPROCS	4096
#define MAXPORTS	32768

/* luaheap's granularity. Machines with room keep the larger chunk and
 * the deeper large-block cache: both trade memory held for allocations
 * avoided, which is the right trade when memory is not the constraint.
 */
#define LUAHEAP_CHUNK		(8 * 1024)
#define LUAHEAP_LARGE_CACHED	4

/* Lua's gc pause, as a percentage of live. The stock 200 -- let the
 * heap double before collecting again -- is the right trade where
 * memory is not the constraint.
 */
#define GCPAUSE		200
