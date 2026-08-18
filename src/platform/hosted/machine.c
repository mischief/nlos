/* the machine, where the machine is a linux process: a monotonic clock
 * for ticks, the host's malloc for every heap, and exit for halt.
 */

#include <errno.h>
#include <malloc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/resource.h>
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

/* how much memory this machine has, which a process otherwise has no
 * answer for. The limit is real: past it malloc returns null, so the
 * shortage the kernel is written to survive is one it can actually
 * meet, and an unbounded guest cannot take the host down with it.
 */
void
hosted_setmem(unsigned long long bytes)
{
	struct rlimit rl = { bytes, bytes };

	memcap = bytes;
	setrlimit(RLIMIT_AS, &rl);
}

/* the cap, less what the allocator holds. `largest` follows `avail`:
 * the host allocator will map a fresh region of whatever is left, so
 * there is no fragmentation story to tell here.
 */
void
platform_meminfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest)
{
	struct mallinfo2 mi = mallinfo2();
	unsigned long long live = mi.uordblks;
	unsigned long long free_bytes = memcap > live ? memcap - live : 0;

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
