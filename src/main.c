#include "efi.h"

EFI_SYSTEM_TABLE *ST;
EFI_BOOT_SERVICES *BS;
EFI_HANDLE self_image;

static void
puts16(CHAR16 *s)
{
	ST->ConOut->OutputString(ST->ConOut, s);
}

static void
putc16(CHAR16 c)
{
	CHAR16 buf[2] = { c, 0 };

	puts16(buf);
}

static EFI_INPUT_KEY
getkey(void)
{
	EFI_INPUT_KEY key;
	UINTN index;

	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_NOT_READY)
		BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
	return key;
}

EFI_STATUS
efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	ST = st;
	BS = st->BootServices;
	self_image = image;

	ST->ConOut->ClearScreen(ST->ConOut);
	puts16(u"lua-os: hello from bare EFI\r\n");
	puts16(u"firmware: ");
	puts16(ST->FirmwareVendor);
	puts16(u"\r\n\r\ntype stuff (esc quits):\r\n");

	for (;;) {
		EFI_INPUT_KEY k = getkey();

		if (k.ScanCode == 0x17)	/* escape */
			break;
		if (k.UnicodeChar == '\r')
			putc16('\n');
		if (k.UnicodeChar != 0)
			putc16(k.UnicodeChar);
	}

	puts16(u"\r\nbye\r\n");
	return EFI_SUCCESS;
}
