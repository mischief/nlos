#ifndef HOSTED_H
#define HOSTED_H

/* what the files of this platform share, and nothing above them sees. */

#include <stddef.h>

/* console.c: the terminal on fd 0/1. console_init puts a tty into raw
 * mode and registers the restore; a console on a pipe is left alone.
 */
void	console_init(void);

/* the descriptor keystrokes arrive on, for the idle poll. */
int	console_infd(void);

/* microseconds on a monotonic clock, which is also platform_ticks's
 * unit. One clock for the shim's tick, the stall and the idle timeout.
 */
unsigned long long hosted_now_us(void);

/* the sockets with an operation outstanding, for the idle wait. Fills
 * `out` and returns how many, never more than NET_POLLMAX.
 */
#define NET_POLLMAX 256
struct pollfd;
int	net_pollfds(struct pollfd *out, int max);

/* a boot parameter by name, or null. What -fw_cfg is on the machines
 * with firmware: the host's way of telling the guest something before
 * it has a filesystem to read it from.
 */
const char *hosted_fwcfg(const char *name);
void	hosted_setfwcfg(const char *name, const char *value);

/* the recording a gnss receiver is replayed from, read from the
 * environment before it is cleared. Null means this machine has none.
 */
void	hosted_setgps(const char *path);

/* the cpus, where a cpu is a host thread. init before anything calls
 * cpu_self, start after the first proc exists -- an ap whose dispatch
 * loop begins on a machine with no live procs parks for good.
 */
int	hosted_smp_init(int want);
void	hosted_smp_start(void);

/* a cpu's wake pipe, and how to empty it. The boot cpu sleeps in the
 * idle poll rather than in platform_cpu_idle, so that poll has to watch
 * this too or work made ready for it waits for the next tick.
 */
int	hosted_wakefd(unsigned cpu);
void	hosted_wakedrain(unsigned cpu);

/* sleep this long, giving the cpu back for the whole of it. */
void	hosted_stall_us(unsigned long us);

/* n bytes from the host's entropy source. 0 on success. */
int	hosted_random(void *buf, size_t n);

/* the machine's memory, set once before anything allocates. */
void	hosted_setmem(unsigned long long bytes);

enum { HOSTED_HEADLESS, HOSTED_GUI };

extern int hosted_display;

/* --gui opens a window; without one platform_have_fb says no. pump
 * drains the host's events and flush repaints, both called from the
 * device reads and from the idle wait, so a window answers whether the
 * machine is busy or asleep. */
int	fb_open(int w, int h);
void	fb_pump(void);
void	fb_flush(void);

#endif
