/* microvm has no ACPI register and no keyboard controller to reset
 * through -- the documented way to end a guest here is a deliberate
 * triple fault (qemu docs/system/i386/microvm.rst, "Triggering a
 * guest-initiated shut down"), which -no-reboot turns into a clean
 * qemu exit instead of a silent restart.
 */

#include <stdint.h>

#include "microvm.h"

struct idtr {
	uint16_t limit;
	uint64_t base;
} __attribute__((packed));

_Noreturn void
machine_reset(void)
{
	static const struct idtr zero = { 0, 0 };

	__asm__ volatile ("lidt %0" : : "m" (zero));
	__asm__ volatile ("int $0x03");
	for (;;)
		__asm__ volatile ("hlt");
}
