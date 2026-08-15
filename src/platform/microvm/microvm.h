#ifndef MICROVM_H
#define MICROVM_H

#include <stddef.h>
#include <stdint.h>

/* pmm.c */
void	pmm_add(uintptr_t base, size_t len);
void	*pmm_alloc(size_t n);
void	pmm_free(void *p, size_t n);
void	pmm_meminfo(size_t *total, size_t *avail, size_t *largest);

/* uart.c */
void	uart_isr(void);
void	uart_irq_enable(void);

/* tsc.c */
void	tsc_calibrate(void);
unsigned long long tsc_hz(void);
const char *tsc_source(void);	/* where tsc_hz came from, for the boot log */
void	platform_stall_us(unsigned long us);

/* lapic.c -- only ever called on a machine intr.c found an APIC on. */
void	lapic_init(void);
void	lapic_timer_arm_periodic(unsigned long long period_100ns);
void	lapic_timer_rearm(void);
unsigned lapic_id(void);
void	lapic_eoi(void);

/* the universal start-up algorithm; see lapic.c. entry must be a 4K
 * page below 1MB, which is what the target begins executing in real
 * mode.
 */
void	lapic_startap(unsigned apicid, unsigned long entry);

/* a fixed-delivery ipi at a vector this kernel chose; see intr.c. */
void	lapic_ipi(unsigned apicid, unsigned vector);

/* the reschedule ipi: wake a cpu that is parked in its idle hlt
 * because work has been put on its queue. Carries nothing.
 */
void	intr_ipi_init(void);
void	intr_resched(unsigned apicid);
void	resched_isr(void);
void	isr_resched(void);

/* smp.c. smp_init claims cpu 0 for the boot processor and must run
 * before anything calls cpu_self(); smp_start_aps starts the rest and
 * must run after the machine has a proc, since an AP goes straight
 * into the dispatch loop and that loop ends when there is nothing to
 * run.
 */
void	idt_load(void);	/* this cpu's IDTR; the table is shared */
void	smp_init(void);
void	smp_start_aps(void);
unsigned long uart_rx_irqs(void);
void	uart_txlock(void);
void	uart_txunlock(void);

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

/* a message-signalled interrupt, which has no line and therefore no
 * controller to program: the device is told a vector and writes it
 * straight at the LAPIC. So routing one is only installing a handler,
 * and ending one is only the LAPIC's end-of-interrupt.
 *
 * intr_alloc_vector hands out the vectors those messages carry, above
 * everything the gsi rule can reach (INTR_VECTOR_BASE + the widest
 * IOAPIC here), so a device's vector cannot collide with a line's. It
 * returns -1 when they run out.
 */
int	intr_alloc_vector(void);
void	intr_route_msi(int vector, void (*handler)(void));
void	intr_eoi_msi(void);
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

/* qemu's microvm wires its eight virtio-mmio slots to consecutive GSIs
 * from here, and which base that is depends on the machine's
 * configuration -- three cases, in microvm_devices_init
 * (hw/i386/microvm.c):
 *
 *	a second ioapic	-> 24, and 24 transports rather than 8
 *	else acpi on	-> 16
 *	else		-> 5
 *
 * 16 is the one our launchers ask for: they pass ioapic2=off (so the
 * slot layout stays the documented eight) and acpi is on, which is
 * microvm's default and which they now pin so it cannot drift.
 *
 * "acpi is on" here means only what qemu's x86_machine_is_acpi_enabled
 * means by it, which is not that this guest has ACPI. It does not: the
 * PVH start_info arrives with rsdp_paddr = 0, and there is no BIOS area
 * to scan, so there is no table to walk and nothing to discover this
 * number from. qemu does build the tables and offer them over fw_cfg
 * (etc/acpi/rsdp, etc/acpi/tables, etc/table-loader), but unassembled --
 * table-loader is a script firmware is expected to execute to place
 * them and patch their pointers, and with -kernel there is no firmware
 * to do it. So the flag that picks this number is one the guest cannot
 * observe, which is exactly how it came to be wrong and stay wrong.
 *
 * This was 5 for a long time, which is the no-acpi case and was simply
 * wrong for the machine we run. Nothing noticed, because a wrong GSI
 * costs nothing until something depends on the interrupt rather than
 * polling: the device raised a line into a pin nobody had unmasked, and
 * every driver here polls. 5 is also implausible on its face -- it
 * would put virtio slots on top of the ISA assignments, and slot 7's
 * neighbour is COM1's own line.
 */
#define VIRTIO_MMIO_GSI_BASE 16

/* pci.c -- the other machine probe; see intr_have_apic for the first.
 * Its answer decides whether the virtio-mmio window in virtio.c exists
 * at all, and it is where a PCI virtio transport would attach.
 */
int	pci_present(void);
uint32_t pci_config_read(int bus, int dev, int fn, int reg);
void	pci_config_write(int bus, int dev, int fn, int reg, uint32_t v);

/* one base address register, resolved. Which address space it lives in
 * is part of the answer and not a property of the machine: the same
 * virtio device is an IO BAR under vmd and a memory BAR on a q35, and
 * only the register itself says which.
 */
#define PCI_NUM_BARS 6

struct pci_bar {
	uint64_t base;		/* 0 if the BAR is unimplemented or unassigned */
	int is_io;
};

/* what a driver needs about a device it found, and nothing more: where
 * it is on the bus, where its registers are, and which line it raises.
 */
struct pci_dev {
	int bus, dev, fn;
	struct pci_bar bar[PCI_NUM_BARS];
	int irq;		/* the interrupt line, as config space names it */
};

int	pci_find(uint16_t vendor, uint16_t device, struct pci_dev *out);

/* find by vendor and either of two device ids -- what a transitional
 * device costs, since it answers to one id and its non-transitional
 * twin to another. Pass 0xffff for `alt` to search for one id only.
 */
int	pci_find2(uint16_t vendor, uint16_t device, uint16_t alt,
	    struct pci_dev *out);

/* walk a device's capability list, returning the config-space offset of
 * the first capability with this id, or 0. `vendor_type` selects among
 * several vendor-specific (0x09) capabilities by the byte at +3, which
 * is how virtio names its structures; pass -1 to take the first.
 */
int	pci_cap_find(const struct pci_dev *pd, uint8_t id, int vendor_type);

/* idt_stubs.S */
void	isr_timer(void);
void	isr_virtio(void);
void	isr_uart(void);

/* lapic.c: end-of-interrupt, which every handler owes the LAPIC before
 * it returns or no further interrupt at that priority is delivered.
 * Drivers call intr_eoi instead; the 8259 wants a different answer.
 */
void	lapic_eoi(void);
unsigned lapic_id(void);

/* reset.c */
_Noreturn void machine_reset(void);

/* boot.S */
void	microvm_main(unsigned long start_info);

#endif
