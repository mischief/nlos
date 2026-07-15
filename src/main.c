#include <stdio.h>

#include "efi.h"
#include "fs.h"
#include "kernel.h"

EFI_SYSTEM_TABLE *ST;
EFI_BOOT_SERVICES *BS;
EFI_HANDLE self_image;

extern void console_write(const char *s, UINTN n);

static void
puts8(const char *s)
{
	UINTN n = 0;

	while (s[n])
		n++;
	console_write(s, n);
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

static void
serial_takeover(void)
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
			    "serial: handle %lu is 16550 _UID %u\n",
			    (unsigned long)i, (unsigned)uid);
			puts8(msg);
			if (uid == COM2_UID) {
				BS->DisconnectController(handles[i], 0, 0);
				puts8("serial: detached firmware from com2\n");
			}
		}
	}
	BS->FreePool(handles);
}

EFI_STATUS
efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	EFI_INPUT_KEY key;
	UINTN index;

	ST = st;
	BS = st->BootServices;
	self_image = image;

	ST->ConOut->ClearScreen(ST->ConOut);
	puts8("lua-os booting\n");

	if (fs_init() != 0)
		puts8("warning: no filesystem on boot volume\n");

	serial_takeover();	/* wrest com2 from the firmware before we poll it */

	if (kernel_init() != 0) {
		puts8("kernel_init failed\n");
		goto out;
	}
	if (kernel_spawn_file("/init.lua") < 0) {
		puts8("failed to spawn /init.lua\n");
		goto out;
	}
	kernel_run();

out:
	puts8("press any key to exit\n");
	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_NOT_READY)
		BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
	return EFI_SUCCESS;
}
