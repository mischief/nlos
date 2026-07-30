#ifndef PLATFORM_H
#define PLATFORM_H

/* the platform layer: efi console/glue and machine bits (src/<arch>).
 * prototypes live here so every definition has one in
 * scope (-Wmissing-prototypes).
 */

#include <stddef.h>

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
