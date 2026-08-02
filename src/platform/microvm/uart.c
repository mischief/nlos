/* 16550 uart, com1 (0x3f8) -- microvm's one ISA serial port (see qemu
 * docs/system/i386/microvm.rst). there is no firmware console fighting
 * for it here, so unlike src/x86_64/uart.c (com2, fighting EFI for the
 * wire) this needs no takeover dance.
 *
 * Receive is meant to be interrupt-driven: the uart raises IRQ 4 when a
 * byte arrives, the handler moves it into a ring, and uart_rx takes from
 * there, with a poll of the port as a fallback.
 *
 * Receive works, end to end. A host write reaches the port, the handler
 * drains it into the ring, uart_rx pops it, pump_serial pushes it to
 * serport and lib/wire.lua hands it to whoever asked: a payload reading
 * the wire gets back the string "hello" for a host write of "hello".
 *
 * It worked all along. What did not was the test payload used to check
 * it, which looked for msg.data on a message that lib/wire.lua delivers
 * as a bare string. Worth knowing before concluding this is broken
 * again.
 *
 * Two real things did come out of the search. uart_init is called
 * twice, by microvm_main and again by kernel_init, and the second call
 * cleared IER and switched receive interrupts back off -- rx_irq_on
 * exists for that. And qemu's main loop sleeps on this machine with
 * nothing to wake it, since pit, rtc and pic are off and the LAPIC
 * timer lives inside KVM, so host input can sit undelivered until
 * something else stirs the loop. That is why identical experiments gave
 * different answers depending on timing.
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

/* kernel_init calls this too, after microvm_main already has -- and on
 * this platform that second call lands after uart_irq_enable and used
 * to undo it, since the first thing here is to clear IER. Remembering
 * that receive was enabled and putting it back is less fragile than
 * depending on who calls whom in what order.
 */
static int rx_irq_on;

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

	if (rx_irq_on)
		outb(COM1 + IER, IER_RX_AVAIL);
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
	rx_irq_on = 1;
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
