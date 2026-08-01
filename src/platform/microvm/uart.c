/* 16550 uart, com1 (0x3f8) -- microvm's one ISA serial port (see qemu
 * docs/system/i386/microvm.rst). there is no firmware console fighting
 * for it here, so unlike src/x86_64/uart.c (com2, fighting EFI for the
 * wire) this needs no takeover dance.
 *
 * Receive is interrupt-driven: the uart raises IRQ 4 when a byte
 * arrives, the handler moves it into a ring, and uart_rx takes from
 * there. Polling the port directly only finds a byte if the kernel
 * happens to look while it is sitting in the fifo, which for an
 * interactive console means input latency bounded by how often the
 * scheduler goes round rather than by the wire.
 *
 * Unverified, and worth knowing before trusting it: no byte has ever
 * been observed arriving here. A marker placed at the inb(RBR) below
 * never fired for anything typed at a microvm guest, under both
 * -serial stdio and -serial mon:stdio, which puts the problem before
 * this file -- LSR_DR is simply never set. Transmit works; the boot log
 * comes out of uart_tx.
 *
 * So the ring and the handler are written but untested, and uart_rx
 * keeps polling the port as a fallback for exactly that reason. Whoever
 * gets serial input working on microvm should check this rather than
 * assume it.
 */

#include "microvm.h"
#include "platform.h"

#define COM1 0x3f8
#define COM1_GSI 4		/* the ISA assignment, unchanged on microvm */
#define UART_VECTOR 0x41	/* virtio has 0x40; see virtio.c */

#define RBR 0	/* receive buffer */
#define THR 0	/* transmit holding */
#define IER 1	/* interrupt enable */
#define IIR 2	/* interrupt identification (read) */
#define FCR 2	/* fifo control (write) */
#define LCR 3	/* line control */
#define MCR 4	/* modem control */
#define LSR 5	/* line status */

#define IER_RX_AVAIL 0x01	/* interrupt when a byte arrives */

#define LSR_DR	 0x01	/* data ready */
#define LSR_THRE 0x20	/* transmit holding empty */

/* single producer (the handler), single consumer (uart_rx), so head and
 * tail each have one writer and no lock is needed. A power of two, so
 * the wrap is a mask.
 */
#define RXRING 256

static volatile unsigned char rxring[RXRING];
static volatile unsigned int rxhead, rxtail;

static inline unsigned char
inb(unsigned short port)
{
	unsigned char v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static inline void
outb(unsigned short port, unsigned char v)
{
	__asm__ volatile ("outb %0, %1" : : "a" (v), "Nd" (port));
}

void
uart_takeover(void)
{
	/* nothing to fight: no firmware owns this port. */
}

void
uart_init(void)
{
	outb(COM1 + IER, 0x00);		/* quiet while reconfiguring */
	outb(COM1 + LCR, 0x80);		/* dlab on */
	outb(COM1 + 0, 0x01);		/* divisor 1: 115200 */
	outb(COM1 + 1, 0x00);
	outb(COM1 + LCR, 0x03);		/* 8n1, dlab off */

	/* trigger on one byte rather than fourteen. This is a console: a
	 * keystroke should raise an interrupt, not wait for thirteen
	 * friends or for the fifo's timeout to give up on them.
	 */
	outb(COM1 + FCR, 0x07);		/* fifo on, both cleared, trigger 1 */
	outb(COM1 + MCR, 0x0B);		/* dtr, rts, out2 */
}

/* routing is separate from uart_init because it cannot happen at the
 * same time: uart_init runs first thing in microvm_main so that panics
 * have somewhere to print, long before the IDT exists.
 */
void
uart_irq_enable(void)
{
	idt_set_vector(UART_VECTOR, isr_uart);
	ioapic_route(COM1_GSI, UART_VECTOR);
	outb(COM1 + IER, IER_RX_AVAIL);
}

/* drain the hardware fifo into the ring. Called from the handler, and
 * from uart_poll for anything that arrived before routing was set up.
 */
static void
uart_drain(void)
{
	while (inb(COM1 + LSR) & LSR_DR) {
		unsigned char c = inb(COM1 + RBR);
		unsigned int next = (rxhead + 1) % RXRING;

		if (next == rxtail)
			return;		/* ring full; drop rather than wrap */
		rxring[rxhead] = c;
		rxhead = next;
	}
}

void
uart_isr(void)
{
	/* reading IIR is what tells the uart the interrupt was seen; the
	 * fifo drain below is what stops it raising again immediately.
	 */
	(void)inb(COM1 + IIR);
	uart_drain();
	lapic_eoi();
}

void
uart_poll(void)
{
	uart_drain();
}

int
uart_rx(void)
{
	if (rxtail == rxhead) {
		/* nothing buffered. Look at the port anyway: bytes that
		 * arrived before uart_irq_enable ran are sitting in the
		 * fifo with no interrupt coming for them.
		 */
		uart_drain();
		if (rxtail == rxhead)
			return -1;
	}

	unsigned char c = rxring[rxtail];

	rxtail = (rxtail + 1) % RXRING;
	return c;
}

void
uart_tx(const char *s, unsigned long n)
{
	while (n--) {
		while (!(inb(COM1 + LSR) & LSR_THRE))
			;
		outb(COM1 + THR, (unsigned char)*s++);
	}
}
