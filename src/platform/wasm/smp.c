/* one cpu, and no interrupts to turn off. A wasm module has one stack
 * and one thread of control, so cpu_self is "the only one" and a wake
 * has nobody to reach.
 */

#include <stddef.h>

#include "cpu.h"
#include "host.h"
#include "platform.h"

static struct cpu boot_cpu = { .self = &boot_cpu, .idx = 0 };

struct cpu *
cpu_self(void)
{
	return &boot_cpu;
}

struct cpu *
cpu_at(unsigned i)
{
	return i == 0 ? &boot_cpu : NULL;
}

unsigned
platform_ncpu(void)
{
	return 1;
}

void
platform_wake_cpu(unsigned i)
{
	(void)i;
}

/* the scheduler idles in the clock's wait, not here: this is only
 * reached by a cpu with no work at all, and there is no other cpu to
 * hand it any.
 */
void
platform_cpu_idle(void)
{
	host_wait(1);
}

void
platform_intr_off(void)
{
}

void
platform_intr_on(void)
{
}
