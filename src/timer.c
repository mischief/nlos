/* the calibrated clock, and the one-shot timers built on it. */

#include <stddef.h>

#include "efi.h"
#include "lock.h"
#include "kernel.h"
#include "kproc.h"
#include "timer.h"
#include "platform.h"

#include "param.h"

#define MAXTIMERS	128	/* outstanding one-shot timers, machine-wide */

extern unsigned long long platform_ticks(void);

/* cycles per millisecond, measured once at boot. platform_ticks is a raw
 * hardware counter, and its rate is whatever this machine runs it at,
 * anywhere from a GHz tsc to a 62.5MHz arm virtual counter. One 100ms
 * stall is enough, at a few parts per million across boots, and both
 * architectures guarantee the constant rate this assumes.
 */
static unsigned long long cyc_per_ms;

/* the counter value kernel_clock_init saw, so uptime_ms is milliseconds
 * since boot rather than since the cpu started counting. 64-bit, and it
 * does not wrap on any relevant timescale, so this is a plain
 * subtraction. The 24-bit ACPI timer that wraps in seconds is not this.
 */
static unsigned long long boot_tsc;

/* until the clock is calibrated there is no rate to divide by, so
 * anything logged before then is stamped 0.
 */
static int clock_ready;

/* the wall-clock slice a proc may hold before the count hook yields it.
 * A slice costs one lap, so this decides how much of the machine goes
 * to scheduling rather than to work. A platform whose lap is expensive
 * overrides it in param.h -- see docs/scheduling.md.
 */
#ifndef QUANTUM_MS
#define QUANTUM_MS	2
#endif

/* how long the rx fifo may go undrained inside the dispatch loop. A
 * quarter of the time 16 bytes take to arrive leaves margin for a proc
 * that overruns its slice, without making the check itself frequent.
 */
#define UART_DRAIN_MS 1

unsigned long long uart_drain_cycles = 1;
unsigned long long quantum_cycles;
const unsigned quantum_ms = QUANTUM_MS;

/* the clock half of calibration, separate so it can run first: until it
 * has, there is no clock to stamp a log line with. The epoch is taken
 * before the stall, so calibration counts as real boot time rather than
 * vanishing from anyone's boot latency measurement.
 */
void
kernel_clock_init(void)
{
	boot_tsc = platform_ticks();

	unsigned long long t0 = boot_tsc;

	BS->Stall(100000);	/* 100ms */

	unsigned long long dt = platform_ticks() - t0;

	cyc_per_ms = dt / 100;
	if (cyc_per_ms == 0)
		cyc_per_ms = 1;	/* refuse to divide by zero later */
	quantum_cycles = cyc_per_ms * QUANTUM_MS;
	uart_drain_cycles = cyc_per_ms * UART_DRAIN_MS / 4;
	if (uart_drain_cycles == 0)
		uart_drain_cycles = 1;
	clock_ready = 1;
}

unsigned long long
kernel_cyc_per_ms(void)
{
	return cyc_per_ms;
}

unsigned long long
uptime_ms(void)
{
	if (!clock_ready)
		return 0;
	return (platform_ticks() - boot_tsc) / cyc_per_ms;
}

/* The wall clock: unix seconds at boot, all a machine with no battery
 * keeps. Unset reads as nil, not 1970. Locked because a 64-bit store
 * is not atomic on every target, and a torn read is another century.
 */
static struct lock timelock = LOCK_INIT;
static long long wall_base_s = -1;	/* unix seconds at boot, or -1 */

/* unix seconds, or 0 when the clock has never been set. */
long long
kernel_walltime(void)
{
	long long base, up = (long long)uptime_ms() / 1000;

	lock(&timelock);
	base = wall_base_s;
	unlock(&timelock);
	return base < 0 ? 0 : base + up;
}

void
kernel_settime(long long unix_s)
{
	lock(&timelock);
	wall_base_s = unix_s - (long long)(uptime_ms() / 1000);
	unlock(&timelock);
}

/* one-shot timers. sys.timer(ms) mints a port, hands the caller its
 * receive right, and records a deadline here; expire_timers pushes one
 * message when the deadline passes and lets the port go. A timer is a
 * port so that recv-with-timeout falls out of thread.alt with no new
 * api, as thread.alt({{port = reply}, {port = sys.timer(500)}}).
 *
 * A flat unsorted array, scanned once per lap. Resolution is the
 * scheduler tick, so a timer fires up to one tick late and never early.
 */
struct ktimer {
	struct kport *port;		/* 0 = free slot */
	unsigned long long due_ms;
};

static struct ktimer timers[MAXTIMERS];

/* release slots whose port died -- the waiter closed its right, or the
 * proc holding it exited.
 */
static void
reap_dead_timers(void)
{
	/* caller holds ipclock: expire_timers already has it, timer_arm
	 * must take it.
	 */
	for (int i = 0; i < MAXTIMERS; i++)
		if (timers[i].port && timers[i].port->dead) {
			port_unref(timers[i].port);
			timers[i].port = 0;
		}
}

int
timer_arm(struct kport *port, unsigned long long ms)
{
	int slot = -1;

	for (int tries = 0; tries < 2 && slot < 0; tries++) {
		for (int i = 0; i < MAXTIMERS; i++)
			if (!timers[i].port) {
				slot = i;
				break;
			}
		/* full: a cancelled timer's slot is held until something
		 * notices its port died, and the caller cannot be asked to
		 * yield first -- a sleep would need a timer of its own to do
		 * that, which is exactly what it cannot get. Reclaim here.
		 */
		if (slot < 0 && tries == 0)
			reap_dead_timers();
	}
	if (slot < 0)
		return -1;

	port->nrights++;	/* the timer table's own ref */
	timers[slot].port = port;
	timers[slot].due_ms = uptime_ms() + ms;
	return 0;
}

void
expire_timers(void)
{
	ipclock_enter();
	unsigned long long now = uptime_ms();

	reap_dead_timers();	/* cancelled ones, before looking at deadlines */
	for (int i = 0; i < MAXTIMERS; i++) {
		struct ktimer *t = &timers[i];

		if (!t->port)
			continue;
		if (now >= t->due_ms) {
			port_push(t->port, (const unsigned char *)"T", 1, 0, 0);
			port_unref(t->port);
			t->port = 0;
		}
	}
	ipclock_leave();
}
