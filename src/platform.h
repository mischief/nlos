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

/* can this machine make tcp connections without frames to build them
 * from? Hosted answers yes, from the host's sockets; everyone else
 * answers no and builds tcp in Lua.
 */
int	platform_have_net(void);

/* can some outstanding operation make progress now? Only outstanding
 * ones: a socket nobody waits on would say yes forever and never idle.
 */
int	platform_net_ready(void);

/* is there a bluetooth controller to exchange HCI packets with? esp32
 * only, where the radio does BLE beside wifi. Everything above HCI is
 * Lua in lib/ble, so this hands over whole packets and no more.
 */
int	platform_have_hci(void);

/* HCI packets taken from the controller since boot. The hci pump's edge
 * detection, kept apart from platform_dev_irqs so a packet wakes the
 * task that wants one.
 */
unsigned long platform_hci_irqs(void);

/* is there a block device? microvm answers by probing for a virtio-blk;
 * efi always says no today, for want of an EFI_BLOCK_IO shim rather
 * than for want of a device -- see the comment on its
 * platform_have_blk. Storage there still comes from the firmware's own
 * filesystem, through los.fs.
 */
int	platform_have_blk(void);

/* is there a writable flash partition? esp32 answers by looking for the
 * luafs partition; the others say no, because their storage is a disk
 * and reaches Lua through platform_have_blk above. It is a second block
 * device rather than a second kind of thing: the same raw sectors, and
 * the same filesystem in Lua on top.
 */
int	platform_have_flash(void);

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
 * ConIn and are the console itself, so it answers no.
 *
 * platform_kbd_read returns the next character, or -1 for none. The
 * kernel drains it into a port of its own -- not the console's -- so
 * the two terminals stay separate all the way up.
 */
int	platform_have_kbd(void);
int	platform_kbd_read(void);

/* a pointing device, on the same terms as the keyboard above: its own
 * port, not the console's.
 *
 * platform_ptr_read answers 1 and fills all three when the position or
 * the buttons have changed since the last call, and 0 otherwise. State
 * rather than a queue, deliberately: a pointer's past positions are of
 * no use to a reader that has fallen behind, so a slow reader should
 * lose resolution and not time. The driver coalesces and this reports
 * whatever the latest is.
 *
 * Coordinates are the display's, in pixels. A device that measures
 * something else -- a touch panel in its own orientation, a ball
 * counting steps -- converts before it gets here, so that one place
 * knows the transform.
 */
int	platform_have_ptr(void);
int	platform_ptr_read(int *x, int *y, int *buttons);

/* the battery, if the machine runs on one. Answers 1 and fills *mv with
 * the pack voltage in millivolts, or 0 for a machine on wall power.
 * Millivolts only: a percentage is a curve over a chemistry, and which
 * curve is policy. lib/ps.lua applies one, so it can be corrected
 * without a reflash.
 */
int	platform_battery(int *mv);

/* console.c */
void	console_write(const char *s, size_t n);
int	console_getchar(void);

/* stop rewriting bytes on the way out, for a program moving a binary
 * stream. A platform whose console writes what it is given need not
 * define it; lib/console.lua treats a missing cons.raw as "nothing to
 * switch".
 */
void	console_setraw(int on);

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

/* re-arm the machine's watchdog for `secs`; 0 disarms it. kernel_run
 * pets it each lap, so a reactor that stops running reboots the
 * machine. A no-op where the firmware has no watchdog.
 */
void platform_watchdog(unsigned secs);

/* <arch>/machine.c */
unsigned long long platform_ticks(void);
_Noreturn void machine_halt(void);
const char *platform_arch(void);

/* RAM present, RAM available, and the largest single run of it.
 * `largest` says whether `avail` can be spent: 100KB free in 2KB pieces
 * refuses a 64KB chunk. Any of the three may be null.
 */
void platform_meminfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest);

/* the pool the lua heap's chunks come from, which is not always the one
 * above. On a board with PSRAM the chunks are there and everything else
 * -- ports, message payloads, DMA -- is in internal sram, so the memory
 * that runs out first is invisible to platform_meminfo. A platform
 * whose chunks come from the same pool answers with the same figures.
 */
void platform_chunkinfo(unsigned long long *total, unsigned long long *avail,
    unsigned long long *largest);

/* the C heap's own accounting: bytes live, the most ever live, blocks
 * live, and allocations since boot. A platform that cannot answer one
 * of them leaves it alone; the caller zeroes first.
 *
 * Not named malloc_stats. That is a libc symbol, and a platform linking
 * a libc resolves it there instead -- newlib's takes no arguments and
 * does nothing, which no warning catches and which reports the stack.
 */
void kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);

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

/* how many cpus are running this kernel. One everywhere except
 * microvm on x86_64, and one there too until smp_init finds more.
 */
unsigned platform_ncpu(void);

/* wake cpu i out of its idle sleep because work was put on its queue.
 * A no-op on a platform with one cpu, and on any cpu that is not
 * asleep -- the caller has already decided it is worth sending.
 */
void platform_wake_cpu(unsigned i);

/* sleep this cpu until an interrupt. Returns when one arrives, which
 * for an AP means the reschedule ipi and nothing else.
 *
 * Must be called with interrupts off -- platform_intr_off() -- and
 * re-enables them itself, atomically with going to sleep. That is the
 * whole contract: an AP dispatches with interrupts on, so a wakeup sent
 * between "my queue is empty" and the sleep would otherwise be taken as
 * an ordinary interrupt, handled, and lost, leaving the cpu asleep with
 * work already on its queue.
 */
void platform_cpu_idle(void);

/* interrupts off and on for this cpu. Used only to close that window;
 * this is not a general critical section and nothing here nests.
 */
void platform_intr_off(void);
void platform_intr_on(void);

/* <arch>/uart.c */
void	uart_takeover(void);	/* wrest the wire port from the firmware */
void	uart_init(void);
void	uart_poll(void);
int	uart_rx(void);
void	uart_tx(const char *s, unsigned long n);

/* <arch>/fwcfg.c */
int	fwcfg_load(const char *name, char **buf, size_t *len);

/* a fw_cfg numeric key rather than a named file: the small fixed set
 * qemu has always had, of which smp.c wants NB_CPUS. Returns 0 on
 * success, -1 if there is no fw_cfg here.
 */
int	fwcfg_key(unsigned key, void *buf, size_t len);

/* <arch>/reloc.c -- called from the entry stub before efi_main */
void	self_relocate(char *base);

#endif
