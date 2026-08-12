#ifndef TIMER_H
#define TIMER_H

/* the calibrated clock, and the one-shot timers built on it. */

#include "kernel.h"

struct kport;

/* milliseconds since kernel_clock_init, the one time base timers and
 * timeouts are denominated in. Reads 0 until that has run.
 */
unsigned long long uptime_ms(void);

/* QUANTUM_MS and the uart drain deadline, in cycles. Both are set by
 * kernel_clock_init, once there is a rate to convert with.
 */
extern unsigned long long quantum_cycles;
extern unsigned long long uart_drain_cycles;

/* set the wall clock from unix seconds. */
void	kernel_settime(long long unix_s);

/* arm a one-shot on `port`, due `ms` from now, taking a reference to it.
 * Returns 0, or -1 when the timer table is full. Caller holds ipclock.
 */
int	timer_arm(struct kport *port, unsigned long long ms);

/* deliver every timer that is due and release the slots of any whose
 * port has died. Takes ipclock itself.
 */
void	expire_timers(void);

#endif
