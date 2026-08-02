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

/* is there a virtio-net to hand raw frames to? microvm only: the efi
 * platform takes tcp and udp from the firmware instead and never sees a
 * frame.
 */
int	platform_have_eth(void);

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

/* console.c */
void	console_write(const char *s, size_t n);
int	console_getchar(void);
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
