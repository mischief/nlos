/* 16550 uart, polled, com2 (0x2f8) — com1 belongs to the firmware
 * console. this is the 9p wire.
 */

#include "platform.h"

#define COM2 0x2f8

#define RBR 0	/* receive buffer */
#define THR 0	/* transmit holding */
#define IER 1	/* interrupt enable */
#define FCR 2	/* fifo control */
#define LCR 3	/* line control */
#define MCR 4	/* modem control */
#define LSR 5	/* line status */

#define LSR_DR	0x01	/* data ready */
#define LSR_THRE 0x20	/* transmit holding empty */

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
uart_init(void)
{
	outb(COM2 + IER, 0x00);		/* no interrupts, we poll */
	outb(COM2 + LCR, 0x80);		/* dlab on */
	outb(COM2 + 0, 0x01);		/* divisor 1: 115200 */
	outb(COM2 + 1, 0x00);
	outb(COM2 + LCR, 0x03);		/* 8n1, dlab off */
	outb(COM2 + FCR, 0xC7);		/* fifo on, clear, 14-byte trigger */
	outb(COM2 + MCR, 0x0B);		/* dtr, rts, out2 */
}

/* software rx ring. the hardware fifo is only 16 bytes and we have no
 * rx interrupt, so anything that blocks the cpu (a big uart_tx, a proc
 * computing for a hook window) would otherwise overflow it and corrupt
 * the 9p stream. uart_poll() drains the fifo into this ring and is
 * called from every such blocking spot; delivery reads the ring.
 * size >= 9p msize so a full message can be in flight while we tx.
 */
#define RXRING 16384			/* power of two */

static unsigned char rxbuf[RXRING];
static unsigned int rxhead, rxtail;	/* head writes, tail reads */

void
uart_poll(void)
{
	while (inb(COM2 + LSR) & LSR_DR) {
		unsigned int nh = (rxhead + 1) & (RXRING - 1);

		if (nh == rxtail)
			return;		/* ring full: leave it in the fifo */
		rxbuf[rxhead] = inb(COM2 + RBR);
		rxhead = nh;
	}
}

int
uart_rx(void)
{
	uart_poll();
	if (rxtail == rxhead)
		return -1;

	unsigned char c = rxbuf[rxtail];

	rxtail = (rxtail + 1) & (RXRING - 1);
	return c;
}

void
uart_tx(const char *s, unsigned long n)
{
	while (n--) {
		while (!(inb(COM2 + LSR) & LSR_THRE))
			uart_poll();	/* keep rx drained while we block */
		outb(COM2 + THR, (unsigned char)*s++);
	}
}
