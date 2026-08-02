/* how a guest ends itself, which is a different answer per hypervisor
 * because neither machine has an ACPI register or a keyboard
 * controller to reset through.
 *
 * qemu's microvm documents a deliberate triple fault (docs/system/i386/
 * microvm.rst, "Triggering a guest-initiated shut down"), which
 * -no-reboot turns into a clean exit instead of a silent restart.
 *
 * OpenBSD vmd has no -no-reboot: a triple fault there is a reset, and
 * the guest comes back up in SeaBIOS looking for a boot disk it does
 * not have, forever. What vmm documents instead is halting with
 * interrupts disabled, which vmx_handle_hlt turns into EIO and vmd
 * turns into a terminated vm (sys/arch/amd64/amd64/vmm_machdep.c).
 *
 * Told apart by the same probe everything else here uses: a machine
 * with no local APIC is not qemu's microvm.
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

	if (!intr_have_apic()) {
		__asm__ volatile ("cli");
		for (;;)
			__asm__ volatile ("hlt");
	}

	__asm__ volatile ("lidt %0" : : "m" (zero));
	__asm__ volatile ("int $0x03");
	for (;;)
		__asm__ volatile ("hlt");
}
