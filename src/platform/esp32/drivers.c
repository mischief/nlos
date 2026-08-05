/* what this machine has: a console and the microSD slot.
 *
 * Every other probe answers no. That is not a stub in the sense of
 * unfinished: kernel_init gates each driver task on these exactly as it
 * gates tcp on have_net, so a machine that answers no simply boots
 * without that task. A T-Deck also has a display, a keyboard, a LoRa
 * radio and wifi, and each arrives here as its own probe plus its own
 * task when someone writes it -- see the framebuffer's two-layer split
 * in AGENTS.md before wiring the display to this.
 */

#include <stddef.h>

#include <esp_system.h>

#include "lauxlib.h"
#include "lua.h"

#include "blk.h"
#include "kbd.h"
#include "efi.h"
#include "esp32.h"
#include "platform.h"

/* The keyboard is the one device here that reports work, and it does so
 * without an interrupt: the matrix cannot raise one (see kbd.c), so the
 * shim scans it while the machine is idle and this counts what it
 * found. Same contract either way -- a number that changes when a
 * device has done something.
 */
unsigned long
platform_dev_irqs(void)
{
	return esp_kbd_irqs();
}

/* Nothing to wait on: idf_shim's WaitForEvent already sleeps until the
 * tick or a keystroke, so there is no event for kernel_run to add.
 */
void *
platform_dev_wait(void)
{
	return 0;
}

/* One console and no wire, so nothing is being arbitrated. Contrast
 * microvm, where the single uart is both and this is a boot-time
 * policy.
 */
int
platform_console_input(void)
{
	return 1;
}

/* los.platform.kbd, for proc 0 only.
 *
 * Deliberately here rather than in kernel.c's driver table. The
 * keyboard is the input half of a second terminal, not the console --
 * the serial port stays the console -- so its owner will be a term task
 * with a PRIV of its own once there is a screen to pair it with. Until
 * then this hook is what lets the boot payload prove the matrix works
 * without adding kernel surface for a task that does not exist yet.
 */
static int
kbd_read(lua_State *L)
{
	int c = esp_kbd_read();

	if (c == 0)
		return 0;		/* nil: nothing new */
	lua_pushlstring(L, (const char[]){ (char)c }, 1);
	return 1;
}

static const luaL_Reg kbdlib[] = {
	{ "read", kbd_read },
	{ NULL, NULL }
};

static int
open_kbd(lua_State *L)
{
	luaL_newlib(L, kbdlib);
	return 1;
}

void
platform_boot_extra_modules(lua_State *L)
{
	if (!esp_kbd_present())
		return;

	luaL_requiref(L, "los.platform.kbd", open_kbd, 0);
	lua_pop(L, 1);
}

int
platform_have_p9(void)
{
	return 0;
}

/* Neither. uart_rx below always answers -1 and uart_tx goes nowhere:
 * the board's one port is the console. There is no firmware and so no
 * ESP. Answering honestly is what keeps two procs and four ports from
 * being spent on tasks that cannot run.
 */
int
platform_have_wire(void)
{
	return 0;
}

int
platform_have_esp(void)
{
	return 0;
}

int
platform_have_eth(void)
{
	return 0;
}

/* the microSD slot. Probing it powers the peripheral rail and brings up
 * the shared SPI bus, so this is also what a display or radio driver
 * would wait behind -- see blk.c before adding a second one.
 */
int
platform_have_blk(void)
{
	return esp_blk_present();
}

int
platform_have_fb(void)
{
	return 0;
}

/* ---- los.platform.cons ---- */

static int
cons_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	console_write(s, n);
	return 0;
}

/* Accepted and ignored: microvm needs this because one uart is both the
 * keyboard and the 9p wire, so a payload has to say which it wants.
 * Here the console owns its input already. Answering rather than
 * erroring keeps one payload shape working on both machines.
 */
static int
cons_claim_input(lua_State *L)
{
	(void)L;
	return 0;
}

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
	{ "claim_input", cons_claim_input },
	{ NULL, NULL }
};

int luaopen_los_platform_cons(lua_State *L);

int
luaopen_los_platform_cons(lua_State *L)
{
	luaL_newlib(L, conslib);
	return 1;
}

/* ---- los.platform.power ---- */

static int
power_reset(lua_State *L)
{
	(void)L;
	esp_restart();
}

static int
power_stall(lua_State *L)
{
	BS->Stall((UINTN)luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg powerlib[] = {
	{ "reset", power_reset },
	{ "stall", power_stall },
	{ NULL, NULL }
};

int luaopen_los_platform_power(lua_State *L);

int
luaopen_los_platform_power(lua_State *L)
{
	luaL_newlib(L, powerlib);
	return 1;
}

/* ---- los.platform.blk: microSD, raw sectors ----
 *
 * The same surface efi and microvm give, minus the yielding: the sdmmc
 * driver's transfers are synchronous, so there is nothing to wait on
 * and no slot to carry across a yield. lib/blkfs.lua turns this into
 * /data and the gpt parser and gefs go above, none of it changed.
 */

static int
blk_capacity(lua_State *L)
{
	if (!esp_blk_present())
		return 0;		/* nil: no device */
	lua_pushinteger(L, (lua_Integer)esp_blk_sectors());
	lua_pushinteger(L, (lua_Integer)esp_blk_secsz());
	return 2;
}

static int
blk_read(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	lua_Integer nsec = luaL_checkinteger(L, 2);
	uint32_t secsz = esp_blk_secsz();
	luaL_Buffer b;
	char *buf;
	size_t len;

	if (lba < 0)
		return luaL_error(L, "blk.read: negative sector");
	if (nsec <= 0 || nsec > ESP_BLK_MAXSEC)
		return luaL_error(L, "blk.read: bad sector count");

	len = (size_t)nsec * secsz;
	buf = luaL_buffinitsize(L, &b, len);
	if (esp_blk_read((uint64_t)lba, (uint32_t)nsec, buf) != 0)
		return luaL_error(L, "blk.read: device error");
	luaL_pushresultsize(&b, len);
	return 1;
}

static int
blk_write(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luaL_checklstring(L, 2, &n);
	uint32_t secsz = esp_blk_secsz();

	if (lba < 0)
		return luaL_error(L, "blk.write: negative sector");
	if (n == 0 || secsz == 0 || n % secsz != 0)
		return luaL_error(L,
		    "blk.write: not a whole number of sectors");
	if (n > (size_t)ESP_BLK_MAXSEC * secsz)
		return luaL_error(L, "blk.write: too large");
	if (esp_blk_write((uint64_t)lba, data, (uint32_t)n) != 0)
		return luaL_error(L, "blk.write: device error");
	lua_pushinteger(L, (lua_Integer)(n / secsz));
	return 1;
}

static const luaL_Reg blk_lib[] = {
	{ "capacity", blk_capacity },
	{ "read", blk_read },
	{ "write", blk_write },
	{ NULL, NULL },
};

int luaopen_los_platform_blk(lua_State *L);

int
luaopen_los_platform_blk(lua_State *L)
{
	luaL_newlib(L, blk_lib);
	return 1;
}

/* ---- the modules this platform has no device for ----
 *
 * Empty tables rather than absent symbols: kernel.c registers each of
 * these by name for whichever task owns it, so the opener has to exist
 * even where the device does not. The matching platform_have_* above
 * answers no, so no task is spawned to call into them anyway.
 *
 * los.efi is empty on the same grounds as microvm's: there is no
 * firmware here to expose.
 */
static const luaL_Reg emptylib[] = {
	{ NULL, NULL }
};

#define EMPTY_MODULE(name)						\
	int luaopen_##name(lua_State *L);				\
	int								\
	luaopen_##name(lua_State *L)					\
	{								\
		luaL_newlib(L, emptylib);				\
		return 1;						\
	}

EMPTY_MODULE(los_efi)
EMPTY_MODULE(los_platform_wire)
EMPTY_MODULE(los_platform_p9)
EMPTY_MODULE(los_platform_eth)
EMPTY_MODULE(los_platform_fb)

/* ---- the wire ----
 *
 * kernel.c's pump_serial calls these unconditionally. There is no
 * second port on this board yet, so the wire reads nothing and writes
 * nowhere; platform_console_input answering yes means pump_serial never
 * has bytes to give it.
 */
void
uart_init(void)
{
}

void
uart_poll(void)
{
}

int
uart_rx(void)
{
	return -1;
}

void
uart_tx(const char *s, unsigned long n)
{
	(void)s;
	(void)n;
}

void
uart_takeover(void)
{
}
