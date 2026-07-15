#include "efi.h"

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

static const char boot_lua[] =
	"print(_VERSION .. ' on bare UEFI')\n"
	"print('sqrt(2)  =', math.sqrt(2))\n"
	"print('2^0.5    =', 2^0.5)\n"
	"print('pi       =', math.pi)\n"
	"print('sin(pi/6)=', math.sin(math.pi/6))\n"
	"print('fmt      =', string.format('%d %x %5.2f %s', 42, 255, 3.14159, 'ok'))\n"
	"local t = {}\n"
	"for i = 1, 10 do t[i] = i * i end\n"
	"print('squares  =', table.concat(t, ' '))\n"
	"print('coroutine=', coroutine.wrap(function() coroutine.yield('works') end)())\n";

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
	puts8("lua-os booting\n\n");

	L = luaL_newstate();
	if (L == NULL) {
		puts8("luaL_newstate failed\n");
		goto out;
	}
	luaL_openlibs(L);

	if (luaL_dostring(L, boot_lua) != LUA_OK) {
		puts8("lua error: ");
		puts8(lua_tostring(L, -1));
		puts8("\n");
	}
	lua_close(L);

out:
	puts8("\npress any key to exit\n");
	while (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_NOT_READY)
		BS->WaitForEvent(1, &ST->ConIn->WaitForKey, &index);
	return EFI_SUCCESS;
}
