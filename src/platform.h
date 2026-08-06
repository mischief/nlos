#ifndef PLATFORM_H
#define PLATFORM_H

/* the platform layer: efi console/glue and machine bits (src/<arch>).
 * prototypes live here so every definition has one in
 * scope (-Wmissing-prototypes).
 */

#include <stddef.h>

#include "lua.h"

/* drivers.c (per platform): extra los.* modules for the boot payload
 * beyond the cons/wire/power grant kernel.c already handles generically
 * -- microvm registers los.platform.rng here if a virtio-rng device was
 * found (src/platform/microvm/virtio_rng.c); efi's is a no-op. declared
 * here so kernel.c's spawn_init needs no per-platform #ifdef.
 */
void	platform_boot_extra_modules(lua_State *L);

/* drivers.c (per platform): is there a virtio-9p device THIS DRIVER can
 * reach? checked once by kernel_init and used to enable/disable the
 * /lib/p9srv.lua driver task the same way have_net/have_udp gate
 * tcp.lua/udp.lua.
 *
 * efi's is always 0 -- not because virtio-9p can't exist under EFI
 * (qemu can attach virtio-9p-pci to any pc/q35 machine, OVMF included),
 * but because src/platform/microvm/virtio.c only speaks virtio-MMIO: a
 * fixed-address register scan with no bus to walk. virtio-9p-pci needs
 * real PCI enumeration (BAR discovery via EFI's PCI I/O protocol or
 * raw config space) that nothing here implements yet. this flag is
 * scoped to "can this driver find one", not "can this platform have
 * one".
 */
int	platform_have_p9(void);

/* is there a second serial port to carry 9p, and an EFI System Partition
 * to serve?
 *
 * These two were assumed universal for as long as every platform was a
 * pc: task/wire.lua and task/espsrv.lua ran with .enabled = 1 and no
 * probe. That assumption cost a pid and a pair of orphaned ports on
 * every boot of any machine without them -- esp32 has neither, and
 * microvm has no ESP -- and, worse, printed "proc load error" and
 * "FAILED to start" on a boot that was perfectly healthy. A log that
 * cries wolf every time is how a real fault goes unnoticed.
 *
 * So they are probes like the rest, and a platform that answers no says
 * "not present" and spawns nothing.
 */
int	platform_have_wire(void);
int	platform_have_esp(void);

/* is there a virtio-net to hand raw frames to? microvm only: the efi
 * platform takes tcp and udp from the firmware instead and never sees a
 * frame.
 */
int	platform_have_eth(void);

/* is there a block device? microvm answers by probing for a virtio-blk;
 * efi always says no today, for want of an EFI_BLOCK_IO shim rather
 * than for want of a device -- see the comment on its
 * platform_have_blk. Storage there still comes from the firmware's own
 * filesystem, through los.fs.
 */
int	platform_have_blk(void);

/* is there a framebuffer? efi answers by probing for a GraphicsOutput
 * (src/platform/efi/gop.c); microvm always says no today, for want of a
 * virtio-gpu driver rather than for want of a device -- see the comment
 * on its platform_have_fb, which is where that story is.
 *
 * a machine booted with no display is the normal case and not a
 * failure, so this gates the /lib/fb.lua task exactly as have_net gates
 * the tcp one. the efi probe caches the protocol it locates, so calling
 * this is also what makes los.platform.fb usable afterwards.
 */
int	platform_have_fb(void);

/* a keyboard that is not the console: the input half of a second
 * terminal, where the console is a serial line the machine also has.
 * The T-Deck and the Cardputer each have one; efi's keys arrive through
 * ConIn and ARE the console, so it answers no.
 *
 * platform_kbd_read returns the next character, or -1 for none. The
 * kernel drains it into a port of its own -- not the console's -- so
 * the two terminals stay separate all the way up.
 */
int	platform_have_kbd(void);
int	platform_kbd_read(void);

/* console.c */
void	console_write(const char *s, size_t n);
int	console_getchar(void);

/* does the console own the serial input, rather than the wire?
 *
 * On efi these are two devices -- the firmware's ConIn is the keyboard
 * and com2 is the wire -- so the question does not arise and the answer
 * is always no. microvm has exactly one uart and both want it, so it is
 * a boot-time policy: whoever the payload hands the console to claims
 * it, and until something does, the bytes go to the wire as before.
 * kernel.c's pump_serial asks before draining.
 */
int	platform_console_input(void);

/* a count of device interrupts taken, rising whenever a device has
 * signalled. Not which device and not how many frames: only "something
 * happened since you last asked", which is all a pump needs to decide
 * whether to wake the driver holding that device's port.
 *
 * A counter rather than a callback because the handler that increments
 * it runs with a proc interrupted and must not touch the scheduler --
 * the same reason virtio.h gives for virtio_irq_count.
 *
 * Zero and unchanging on a platform whose devices raise nothing a
 * driver could sleep on.
 */
unsigned long platform_dev_irqs(void);

/* something kernel_run can put in its idle WaitForEvent, so that a
 * machine with nothing runnable wakes on a frame rather than on the
 * next tick. An EFI_EVENT on efi (SNP's WaitForPacket), returned as
 * void * because platform.h has no efi types in it.
 *
 * 0 means "nothing to wait on, keep polling", which is both a platform
 * without one and a machine with no card. microvm returns 0 because it
 * does not need this: its shim's WaitForEvent already halts until an
 * interrupt, and virtio-net raises a real one.
 *
 * Whatever is returned must have no other observer. A firmware Event's
 * signaled state is consumed by whoever looks first, so anything that
 * also CheckEvents it would find it already taken -- see
 * docs/uefi-notes.md, which is where that cost a week.
 */
void *platform_dev_wait(void);
_Noreturn void platform_abort(const char *why);

/* <arch>/machine.c */
unsigned long long platform_ticks(void);
_Noreturn void machine_halt(void);
const char *platform_arch(void);

/* what the firmware says about RAM: bytes present, and bytes still
 * available. malloc reaches AllocatePool directly rather than carving an
 * arena, so `avail` is the remaining budget for everything -- lua heaps
 * included -- and not a curiosity.
 */
void platform_meminfo(unsigned long long *total, unsigned long long *avail);

/* where the shared lua heap's chunks come from.
 *
 * malloc on a machine with one kind of memory, which is three of the
 * four. On the esp32 it is a choice: a board with PSRAM has 8MB of it
 * beside a few hundred KB of internal sram, and the lua heaps belong in
 * the former. Asking here rather than letting a size threshold decide
 * (CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL) is deliberate -- that coupling
 * silently kept a whole heap out of PSRAM once, because the chunk size
 * had been tuned on the board that has none.
 *
 * n is passed back to the free so an allocator that needs the size has
 * it; malloc-based ones ignore it.
 */
void *platform_chunk_alloc(size_t n);
void platform_chunk_free(void *p, size_t n);

/* <arch>/uart.c */
void	uart_takeover(void);	/* wrest the wire port from the firmware */
void	uart_init(void);
void	uart_poll(void);
int	uart_rx(void);
void	uart_tx(const char *s, unsigned long n);

/* <arch>/fwcfg.c */
int	fwcfg_load(const char *name, char **buf, size_t *len);

/* <arch>/reloc.c -- called from the entry stub before efi_main */
void	self_relocate(char *base);

#endif
