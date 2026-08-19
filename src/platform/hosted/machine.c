/* the machine, where the machine is a linux process: a monotonic clock
 * for ticks, the host's malloc for every heap, and exit for halt.
 */

#include <errno.h>
#include <stdatomic.h>
#include <malloc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

#include "hosted.h"
#include "platform.h"

unsigned long long
hosted_now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000ULL +
	    (unsigned long long)ts.tv_nsec / 1000ULL;
}

/* nanoseconds, so kernel_clock_init's calibration lands on a round
 * million cycles per millisecond. The counter is monotonic and does not
 * stop while the process is descheduled, which is what uptime wants.
 */
unsigned long long
platform_ticks(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ULL +
	    (unsigned long long)ts.tv_nsec;
}

/* every proc has exited, or something asked to power off. A process
 * ends rather than spins, so the exit status is what a harness reads.
 */
_Noreturn void
machine_halt(void)
{
	exit(0);
}

const char *
platform_arch(void)
{
#if defined(__x86_64__)
	return "x86_64";
#elif defined(__aarch64__)
	return "aarch64";
#elif defined(__riscv) && __riscv_xlen == 64
	return "riscv64";
#else
	return "unknown";
#endif
}

static unsigned long long memcap;

/* atomic because every cpu allocates: the check and the add have to be
 * one step, or two cpus both find room for the last chunk and the cap
 * is a suggestion. memcap is written once before any cpu starts.
 */
static atomic_ullong memused;

/* how much memory this machine has. Not an rlimit: that bounds the
 * process, so every mapping the host's own libraries make would count
 * against the guest, and SDL's GL stack reserves hundreds of megabytes
 * before the guest has allocated anything. The figure is the fake
 * machine's, so it is counted where the guest's memory comes from. */
void
hosted_setmem(unsigned long long bytes)
{
	memcap = bytes;
}

/* the cap, less what the allocator holds. `largest` follows `avail`:
 * the host allocator will map a fresh region of whatever is left, so
 * there is no fragmentation story to tell here.
 */
void
platform_meminfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest)
{
	unsigned long long used = atomic_load_explicit(&memused,
	    memory_order_relaxed);
	unsigned long long free_bytes = memcap > used ? memcap - used : 0;

	if (total)
		*total = memcap;
	if (avail)
		*avail = free_bytes;
	if (largest)
		*largest = free_bytes;
}

/* one pool: luaheap's chunks come from the same malloc as everything
 * else.
 */
void
platform_chunkinfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest)
{
	platform_meminfo(total, avail, largest);
}

/* only what the host allocator actually knows. It keeps no high-water
 * mark and no call count, so peak, blocks and total stay untouched --
 * the caller zeroes first, and a number sampled here would be the
 * largest anyone happened to ask about rather than the largest reached.
 */
void
kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total)
{
	struct mallinfo2 mi = mallinfo2();

	if (live)
		*live = mi.uordblks;
	(void)peak;
	(void)blocks;
	(void)total;
}

/* the boot parameters, which are few and set once at startup. A list
 * rather than a table: nothing here has more than a handful.
 */
#define MAXFWCFG 8

static struct {
	const char *name;
	char *value;
} fwcfg[MAXFWCFG];

static int nfwcfg;

void
hosted_setfwcfg(const char *name, const char *value)
{
	if (nfwcfg >= MAXFWCFG || !value)
		return;
	fwcfg[nfwcfg].name = name;
	fwcfg[nfwcfg].value = strdup(value);
	if (fwcfg[nfwcfg].value)
		nfwcfg++;
}

const char *
hosted_fwcfg(const char *name)
{
	for (int i = 0; i < nfwcfg; i++)
		if (strcmp(fwcfg[i].name, name) == 0)
			return fwcfg[i].value;
	return NULL;
}

/* the kernel's entropy, from the kernel that is actually underneath.
 * getrandom blocks only before the host pool is first seeded, which a
 * process started from a shell is long past.
 */
int
hosted_random(void *buf, size_t n)
{
	char *p = buf;

	while (n > 0) {
		ssize_t r = getrandom(p, n, 0);

		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += r;
		n -= (size_t)r;
	}
	return 0;
}

/* everything a guest can grow without bound arrives here: luaheap's
 * chunks and los.buf's buffers both. What does not is the kernel's own
 * tables, which MAXPROCS and MAXPORTS bound instead. Refusing is what
 * the kernel is written to survive -- it releases its caches, and if
 * that is not enough gives up the largest expendable proc.
 */
void *
platform_chunk_alloc(size_t n)
{
	unsigned long long used = atomic_load_explicit(&memused,
	    memory_order_relaxed);
	void *p;

	/* take the room first, then the memory: claiming it after the
	 * malloc would let two cpus past the same last chunk.
	 */
	do {
		if (memcap && used + n > memcap)
			return NULL;
	} while (!atomic_compare_exchange_weak_explicit(&memused, &used,
	    used + n, memory_order_relaxed, memory_order_relaxed));

	p = malloc(n);
	if (!p)
		atomic_fetch_sub_explicit(&memused, n, memory_order_relaxed);
	return p;
}

void
platform_chunk_free(void *p, size_t n)
{
	if (p)
		atomic_fetch_sub_explicit(&memused, n, memory_order_relaxed);
	free(p);
}
