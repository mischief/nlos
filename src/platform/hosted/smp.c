/* more than one cpu, where a cpu is a host thread.
 *
 * The kernel's own smp machinery is untouched: this supplies the four
 * things src/cpu.h and kernel_run_ap ask a platform for -- which cpu am
 * I, how many are there, wake that one, and sleep until woken.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "cpu.h"
#include "hosted.h"
#include "kernel.h"
#include "platform.h"

static struct cpu cpus[NCPU];
static int ncpu = 1;

/* which cpu this thread is. A thread-local pointer where microvm reads
 * %gs: the same question, answered by whatever the machine has.
 */
static __thread struct cpu *self;

/* one pipe per cpu, and what makes the sleep below safe. A wake sent
 * between "my queue is empty" and the sleep is a byte already in the
 * pipe, so the poll returns at once rather than missing it -- the race
 * microvm closes by keeping interrupts off across the same window.
 */
static int wake[NCPU][2];

struct cpu *
cpu_self(void)
{
	return self;
}

struct cpu *
cpu_at(unsigned i)
{
	return i < (unsigned)ncpu ? &cpus[i] : 0;
}

unsigned
platform_ncpu(void)
{
	return (unsigned)ncpu;
}

int
hosted_wakefd(unsigned i)
{
	return i < (unsigned)ncpu ? wake[i][0] : -1;
}

/* drain whatever woke us. Bytes are a count of wakes nobody has looked
 * at yet, and one look answers all of them.
 */
void
hosted_wakedrain(unsigned i)
{
	char buf[64];

	if (i >= (unsigned)ncpu)
		return;
	while (read(wake[i][0], buf, sizeof buf) > 0)
		;
}

void
platform_wake_cpu(unsigned i)
{
	if (i >= (unsigned)ncpu)
		return;
	/* a full pipe is a wake already pending, which is the same
	 * message: write what fits and lose nothing that matters.
	 */
	if (write(wake[i][1], "w", 1) < 0 && errno != EAGAIN)
		return;
}

/* sleep until this cpu is woken. No timeout: a wake that never comes is
 * a bug worth finding rather than one to recover from quietly, and the
 * boot cpu keeps the machine running either way.
 */
void
platform_cpu_idle(void)
{
	struct pollfd pfd = { .fd = wake[self->idx][0], .events = POLLIN };

	while (poll(&pfd, 1, -1) < 0 && errno == EINTR)
		;
	hosted_wakedrain(self->idx);
}

/* nothing to mask: this machine has no interrupts, and the window they
 * close on microvm is closed here by the pipe.
 */
void
platform_intr_off(void)
{
}

void
platform_intr_on(void)
{
}

static void *
ap_main(void *arg)
{
	self = arg;
	kernel_run_ap();
	return NULL;
}

/* the boot cpu, before anything calls cpu_self. */
int
hosted_smp_init(int want)
{
	if (want < 1)
		want = 1;
	if (want > NCPU)
		want = NCPU;
	ncpu = want;

	for (int i = 0; i < ncpu; i++) {
		cpus[i].self = &cpus[i];
		cpus[i].idx = (unsigned)i;
		cpus[i].apicid = (unsigned)i;
		if (pipe(wake[i]) != 0)
			return -1;
		/* both ends: the write must not block when a cpu is slow
		 * to look, and the read is what the sleep polls for.
		 */
		fcntl(wake[i][0], F_SETFL, O_NONBLOCK);
		fcntl(wake[i][1], F_SETFL, O_NONBLOCK);
	}
	self = &cpus[0];
	return 0;
}

/* the other cpus, and after the first proc exists: an ap whose dispatch
 * loop starts on a machine with no live procs falls straight out of it
 * and parks for good.
 */
void
hosted_smp_start(void)
{
	for (int i = 1; i < ncpu; i++) {
		pthread_t t;

		if (pthread_create(&t, NULL, ap_main, &cpus[i]) != 0) {
			kernel_log("smp: a cpu would not start");
			ncpu = i;
			return;
		}
		pthread_detach(t);
	}
}
