#ifndef MICROVM_H
#define MICROVM_H

#include <stddef.h>
#include <stdint.h>

/* pmm.c */
void	pmm_init(uintptr_t base, size_t len);
void	*pmm_alloc(size_t n);
void	pmm_free(void *p, size_t n);
void	pmm_meminfo(size_t *total, size_t *avail);

/* tsc.c */
void	tsc_calibrate(void);
unsigned long long tsc_hz(void);
void	platform_stall_us(unsigned long us);

/* lapic.c */
void	lapic_init(void);
void	lapic_timer_arm_periodic(unsigned long long period_100ns);
unsigned long long lapic_ticks(void);
void	lapic_timer_isr(void);

/* idt.c */
void	idt_init(void);
void	idt_set_vector(int n, void (*handler)(void));

/* idt_stubs.S */
void	isr_timer(void);

/* reset.c */
_Noreturn void machine_reset(void);

/* boot.S */
void	microvm_main(unsigned long start_info);

#endif
