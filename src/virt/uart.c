/* the 9p wire on qemu's virt machines: a 16550 on pci, polled.
 *
 * x86_64 has com2 at a fixed io port and the firmware console on com1.
 * virt has exactly one uart -- a pl011 on aarch64, an ns16550a on
 * riscv64 -- and the firmware console owns it, so the second port has
 * to be added (-device pci-serial, see scripts/arch.sh) and then
 * found. we ask the firmware for it via PciIo rather than walking ecam
 * ourselves, because the ecam and io window addresses move between
 * machine types and qemu versions while the protocol does not. that
 * also means every register access is a firmware call, which is why tx
 * goes out in fifo-sized batches.
 *
 * nothing below is arch-specific -- it is all EFI_PCI_IO_PROTOCOL --
 * which is why it lives here rather than under src/<arch>/.
 *
 * with no such device the wire is simply absent: every entry point
 * here is a no-op and the 9p-over-com2 task talks to nothing.
 */

#include <stdio.h>
#include <string.h>

#include "efi.h"
#include "kernel.h"
#include "platform.h"

#define RBR 0	/* receive buffer */
#define THR 0	/* transmit holding */
#define IER 1	/* interrupt enable */
#define FCR 2	/* fifo control */
#define LCR 3	/* line control */
#define MCR 4	/* modem control */
#define LSR 5	/* line status */

#define LSR_DR	0x01	/* data ready */
#define LSR_THRE 0x20	/* transmit holding empty */

#define TXFIFO	16	/* 16550 transmit fifo depth */

static EFI_GUID pci_io_guid = { 0x4cf5b200, 0x68b8, 0x4ca5,
	{ 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a } };

/* the serial controller we found, or null for "no wire on this box" */
static EFI_PCI_IO_PROTOCOL *wire;

static unsigned char
rd(unsigned reg)
{
	UINT8 v = 0;

	wire->Io.Read(wire, EfiPciIoWidthUint8, 0, reg, 1, &v);
	return v;
}

static void
wr(unsigned reg, unsigned char v)
{
	UINT8 b = v;

	wire->Io.Write(wire, EfiPciIoWidthUint8, 0, reg, 1, &b);
}

/* first pci device with class 07 subclass 00 (serial controller).
 * pci enumeration has already sized and placed its bars by the time an
 * application runs; all that is left is to switch io decoding on.
 */
static void
find_wire(void)
{
	EFI_HANDLE *handles = 0;
	UINTN nhandles = 0;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &pci_io_guid, 0,
	    &nhandles, &handles) != EFI_SUCCESS || !handles)
		return;

	for (UINTN i = 0; i < nhandles; i++) {
		EFI_PCI_IO_PROTOCOL *p = 0;
		UINT32 id = 0, cls = 0;

		if (BS->HandleProtocol(handles[i], &pci_io_guid,
		    (void **)&p) != EFI_SUCCESS || !p)
			continue;
		if (p->Pci.Read(p, EfiPciIoWidthUint32, 0, 1, &id) !=
		    EFI_SUCCESS)
			continue;
		if (p->Pci.Read(p, EfiPciIoWidthUint32, 8, 1, &cls) !=
		    EFI_SUCCESS)
			continue;
		if ((cls >> 16) != 0x0700)	/* class:subclass */
			continue;

		char msg[80];

		snprintf(msg, sizeof msg,
		    "serial: pci %04x:%04x is the 9p wire",
		    (unsigned)(id & 0xffff), (unsigned)(id >> 16));
		kernel_log(msg);

		/* enumeration placed the io bar but left decoding off, so
		 * switch it on in the command register directly. the
		 * polite route -- Attributes(Enable, ATTRIBUTE_IO) --
		 * answers EFI_UNSUPPORTED here: ArmVirtQemu's root bridge
		 * does not advertise io in its supported mask (measured:
		 * 0xe700) even though it assigns io bars and translates
		 * Io.Read/Write onto the machine's pio window perfectly
		 * well. RiscVVirtQemu behaves the same. so the attribute
		 * call cannot be the mechanism and the register write is
		 * not a shortcut around one.
		 */
		UINT32 cmd = 0;

		p->Pci.Read(p, EfiPciIoWidthUint32, 4, 1, &cmd);
		cmd |= 1;	/* io space enable */
		p->Pci.Write(p, EfiPciIoWidthUint32, 4, 1, &cmd);

		wire = p;
		break;
	}
	BS->FreePool(handles);
}

/* nothing to wrest back here: the firmware console is the machine's
 * own uart, and neither ArmVirtQemu nor RiscVVirtQemu ships a driver
 * that binds a pci serial port. kept as the platform hook so main.c
 * stays arch-blind.
 */
void
uart_takeover(void)
{
	if (!wire)
		find_wire();
}

void
uart_init(void)
{
	if (!wire)
		find_wire();
	if (!wire)
		return;

	wr(IER, 0x00);		/* no interrupts, we poll */
	wr(LCR, 0x80);		/* dlab on */
	wr(0, 0x01);		/* divisor 1: 115200 */
	wr(1, 0x00);
	wr(LCR, 0x03);		/* 8n1, dlab off */
	wr(FCR, 0xC7);		/* fifo on, clear, 14-byte trigger */
	wr(MCR, 0x0B);		/* dtr, rts, out2 */
}

/* software rx ring, for the same reason as x86_64: a 16-byte hardware
 * fifo and no rx interrupt means anything that blocks the cpu would
 * overflow it and corrupt the 9p stream. size >= 9p msize.
 */
#define RXRING 16384			/* power of two */

static unsigned char rxbuf[RXRING];
static unsigned int rxhead, rxtail;	/* head writes, tail reads */

void
uart_poll(void)
{
	if (!wire)
		return;
	while (rd(LSR) & LSR_DR) {
		unsigned int nh = (rxhead + 1) & (RXRING - 1);

		if (nh == rxtail)
			return;		/* ring full: leave it in the fifo */
		rxbuf[rxhead] = rd(RBR);
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
	if (!wire)
		return;
	while (n) {
		unsigned char batch[TXFIFO];
		unsigned long k = n < TXFIFO ? n : TXFIFO;

		for (unsigned long i = 0; i < k; i++)
			batch[i] = (unsigned char)s[i];

		/* THRE means the whole fifo is free, so one wait covers
		 * the batch. keep rx drained while we spin.
		 */
		while (!(rd(LSR) & LSR_THRE))
			uart_poll();
		wire->Io.Write(wire, EfiPciIoWidthFifoUint8, 0, THR, k, batch);
		s += k;
		n -= k;
	}
}
