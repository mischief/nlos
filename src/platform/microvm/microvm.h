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

/* lapic.c -- only ever called on a machine intr.c found an APIC on. */
void	lapic_init(void);
void	lapic_timer_arm_periodic(unsigned long long period_100ns);
void	lapic_timer_rearm(void);

/* i8259.c / i8253.c -- and only ever on a machine that has neither. */
void	pic_init(void);
void	pic_unmask(int irq);
void	pic_mask(int irq);
void	pic_eoi(int irq);
void	pit_arm_periodic(unsigned long long period_100ns);

/* intr.c -- the seam. A driver names the line it is wired to and
 * nothing else: which controller answers, and therefore which vector
 * the line gets, is decided here at boot.
 */
int	intr_have_apic(void);
void	intr_init(void);
void	intr_route(int gsi, void (*handler)(void));
void	intr_mask(int gsi);
void	intr_eoi(int gsi);
void	timer_arm_periodic(unsigned long long period_100ns);
unsigned long long timer_ticks(void);
void	timer_isr(void);

/* vector = INTR_VECTOR_BASE + gsi, on both controllers. The 8259 makes
 * that rule (its vectors are base + irq by construction) and the IOAPIC
 * does not mind, since it can raise any vector for any line.
 */
#define INTR_VECTOR_BASE 0x40

/* irq 0 on the 8259 side; unused on the IOAPIC side, where the LAPIC
 * timer delivers through its own LVT and simply takes the same vector.
 */
#define TIMER_GSI 0

/* idt.c */
void	idt_init(void);
void	idt_set_vector(int n, void (*handler)(void));

/* ioapic.c -- routing a device line to a vector, which the LAPIC timer
 * never needed because it delivers through its own local LVT. Reached
 * through intr.c, not called directly by drivers.
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

/* pci.c -- the other machine probe; see intr_have_apic for the first.
 * Its answer decides whether the virtio-mmio window in virtio.c exists
 * at all, and it is where a PCI virtio transport would attach.
 */
int	pci_present(void);
uint32_t pci_config_read(int bus, int dev, int fn, int reg);

/* idt_stubs.S */
void	isr_timer(void);
void	isr_virtio(void);
void	isr_uart(void);

/* lapic.c: end-of-interrupt, which every handler owes the LAPIC before
 * it returns or no further interrupt at that priority is delivered.
 * Drivers call intr_eoi instead; the 8259 wants a different answer.
 */
void	lapic_eoi(void);

/* reset.c */
_Noreturn void machine_reset(void);

/* boot.S */
void	microvm_main(unsigned long start_info);

#endif
