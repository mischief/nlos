#include "efi.h"
#include "fs.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

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
	lua_State *L;
	EFI_INPUT_KEY key;
	UINTN index;

	ST = st;
	BS = st->BootServices;
	self_image = image;

	ST->ConOut->ClearScreen(ST->ConOut);
	puts8("lua-os booting\n");

	if (fs_init() != 0)
		puts8("warning: no filesystem on boot volume\n");

	L = luaL_newstate();
	if (L == NULL) {
		puts8("luaL_newstate failed\n");
		goto out;
	}
	luaL_openlibs(L);

	if (luaL_dofile(L, "/init.lua") != LUA_OK) {
		puts8("init.lua error: ");
		puts8(lua_tostring(L, -1));
		puts8("\n");
	}
	lua_close(L);

out:
	puts8("press any key to exit\n");
	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_NOT_READY)
		BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
	return EFI_SUCCESS;
}
