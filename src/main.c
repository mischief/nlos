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
