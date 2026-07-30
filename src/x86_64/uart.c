/* 16550 uart, polled, com2 (0x2f8) — com1 belongs to the firmware
 * console. this is the 9p wire.
 */

#include <stdio.h>
#include <string.h>

#include "efi.h"
#include "kernel.h"
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

/* the firmware layers a terminal/console on com2 and feeds it into
 * ConIn, which both steals our raw 9p bytes off 0x2f8 and leaks the
 * handshake to the repl. walk every SerialIo handle, find the one whose
 * ACPI node is the com2 16550 (PNP0501, _UID 1), and DisconnectController
 * it so the firmware lets go of the port. com1 (the console) is left
 * alone. boot-services-era crutch; disappears once we stop using efi
 * consoles entirely. we log every serial handle's _UID so the mapping
 * is visible if it ever differs from what we expect.
 */
static EFI_GUID serial_io_guid = { 0xBB25CF6F, 0xF1D4, 0x11D2,
	{ 0x9A, 0x0C, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0xFD } };
static EFI_GUID dev_path_guid = { 0x09576e91, 0x6d3f, 0x11d2,
	{ 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } };

#define COM2_UID 1


void
uart_takeover(void)
{
	EFI_HANDLE *handles = 0;
	UINTN nhandles = 0;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &serial_io_guid, 0,
	    &nhandles, &handles) != EFI_SUCCESS || !handles)
		return;

	for (UINTN i = 0; i < nhandles; i++) {
		EFI_DEVICE_PATH_PROTOCOL *dp = 0;

		if (BS->HandleProtocol(handles[i], &dev_path_guid,
		    (void **)&dp) != EFI_SUCCESS || !dp)
			continue;

		/* walk the path; a serial controller carries an ACPI
		 * PNP0501 node whose _UID selects com1 (0) vs com2 (1).
		 */
		int found = 0;
		UINT32 uid = 0;
		EFI_DEVICE_PATH_PROTOCOL *n = dp;

		while (n->Type != END_DEVICE_PATH_TYPE) {
			UINT16 len = n->Length[0] | (n->Length[1] << 8);

			if (len < sizeof *n)
				break;	/* malformed, stop */
			if (n->Type == ACPI_DEVICE_PATH &&
			    n->SubType == ACPI_DP) {
				ACPI_HID_DEVICE_PATH *a = (void *)n;

				if (a->HID == EISA_PNP_ID_SERIAL) {
					found = 1;
					uid = a->UID;
				}
			}
			n = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)n + len);
		}

		if (found) {
			char msg[64];

			snprintf(msg, sizeof msg,
			    "serial: handle %lu is 16550 _UID %u",
			    (unsigned long)i, (unsigned)uid);
			kernel_log(msg);
			if (uid == COM2_UID) {
				BS->DisconnectController(handles[i], 0, 0);
				kernel_log("serial: detached firmware "
				    "from com2");
			}
		}
	}
	BS->FreePool(handles);
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
