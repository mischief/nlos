#ifndef MICROVM_H
#define MICROVM_H

#include <stddef.h>
#include <stdint.h>

/* pmm.c */
void	pmm_add(uintptr_t base, size_t len);
void	*pmm_alloc(size_t n);
void	pmm_free(void *p, size_t n);
void	pmm_meminfo(size_t *total, size_t *avail);

/* uart.c */
void	uart_isr(void);
void	uart_irq_enable(void);

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

/* ioapic.c -- routing a device line to a vector, which the LAPIC timer
 * never needed because it delivers through its own local LVT.
 */
void	ioapic_init(void);
int	ioapic_pins(void);
void	ioapic_route(int gsi, int vector);
void	ioapic_mask(int gsi);

/* qemu's microvm wires the eight virtio-mmio slots to consecutive GSIs
 * from here (hw/i386/microvm.c, VIRTIO_MMIO_IRQ_BASE), which is the
 * same fixed layout virtio.c's slot scan depends on.
 */
#define VIRTIO_MMIO_GSI_BASE 5

/* idt_stubs.S */
void	isr_timer(void);
void	isr_virtio(void);
void	isr_uart(void);

/* lapic.c: end-of-interrupt, which every handler owes the LAPIC before
 * it returns or no further interrupt at that priority is delivered.
 */
void	lapic_eoi(void);

/* reset.c */
_Noreturn void machine_reset(void);

/* boot.S */
void	microvm_main(unsigned long start_info);

#endif
