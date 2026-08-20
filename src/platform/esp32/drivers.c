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
#include <string.h>

#include <esp_random.h>
#include <esp_system.h>

#include "lauxlib.h"
#include "lua.h"

#include "blk.h"
#include "flashblk.h"
#include "kbd.h"
#include "ball.h"
#include "touch.h"
#include "lora.h"
#include "lcd.h"
#include "wifi.h"
#include "ble.h"

#include "efi.h"
#include "esp32.h"
#include "buf.h"
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
	/* the radio counts beside the keyboard: a frame arriving is work
	 * the scheduler has to wake for, and a machine that only woke for
	 * keystrokes would answer the network at the speed someone typed.
	 */
	return esp_kbd_irqs() + esp_wifi_irqs();
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

/* los.platform.rng. esp_fill_random is a true generator only while an
 * RF subsystem runs; platform_have_eth brings the radio up at probe
 * time, before any task that draws from this one is spawned.
 */

#define RNG_MAX_BYTES 65536	/* one request's worth, as microvm has */

static int
rng_bytes(lua_State *L)
{
	lua_Integer n = luaL_checkinteger(L, 1);
	luaL_Buffer b;
	char *buf;

	if (n < 0 || n > RNG_MAX_BYTES)
		return luaL_error(L, "rng.bytes: n out of range (0-%d)",
		    RNG_MAX_BYTES);

	buf = luaL_buffinitsize(L, &b, (size_t)n);
	if (n > 0)
		esp_fill_random(buf, (size_t)n);
	luaL_pushresultsize(&b, (size_t)n);
	return 1;
}

static const luaL_Reg rnglib[] = {
	{ "bytes", rng_bytes },
	{ NULL, NULL }
};

int luaopen_los_platform_rng(lua_State *L);

int
luaopen_los_platform_rng(lua_State *L)
{
	luaL_newlib(L, rnglib);
	return 1;
}

void
platform_boot_extra_modules(lua_State *L)
{
	/* the rng first, and unconditionally: the tcp task is handed this
	 * function for the rng alone, and a board with no keyboard would
	 * otherwise leave it unable to open a connection.
	 */
	luaL_requiref(L, "los.platform.rng", luaopen_los_platform_rng, 0);
	lua_pop(L, 1);

	/* the radio, which says what it found either way. Nothing drives
	 * it yet: this is the probe, and what it proves is the wiring.
	 */
	esp_lora_present();

	/* say so either way, the way init reports every other device.
	 * A keyboard that did not answer is otherwise indistinguishable
	 * from one whose module nobody happened to require, and on the
	 * T-Deck the difference is a peripheral rail that came up late.
	 */
	if (!esp_kbd_present()) {
		static const char no[] = "kbd: not present, no keyboard "
		    "this boot\n";

		console_write(no, sizeof no - 1);
		return;
	}
	{
		static const char yes[] = "kbd: present\n";

		console_write(yes, sizeof yes - 1);
	}

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
 * ESP. A truthful answer keeps two procs and four ports from
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
	/* The radio is brought up at probe time, not at association: an
	 * interface exists whether or not it has joined a network, the
	 * way a NIC exists with no cable in it. task/eth.lua and the
	 * stack above it therefore start at boot, and carry nothing until
	 * that task is sent a "wifi" op naming an ssid.
	 */
	return esp_wifi_bringup() == 0;
}

int
platform_have_hci(void)
{
	/* Up at probe time for the same reason the radio is: a controller
	 * exists whether or not anything is advertising on it.
	 */
	return esp_ble_bringup() == 0;
}

int
platform_have_lora(void)
{
	return esp_lora_present();
}

unsigned long
platform_hci_irqs(void)
{
	return esp_ble_irqs();
}

/* no blockdev (yet) */
int
platform_have_blk(void)
{
	return 0;
}

/* Every board, unlike the card: the partition is in the image the
 * bootloader just ran from, so it exists wherever this build does.
 */
int
platform_have_flash(void)
{
	return esp_flashblk_present(0);
}

int
platform_have_fb(void)
{
	return luaos_lcd_present();
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

/* cons.raw(on) -- stop translating \n on the way out, so a binary
 * stream survives. task/cons.lua calls this from rawon/rawoff where the
 * platform offers it.
 */
static int
cons_raw(lua_State *L)
{
	console_setraw(lua_toboolean(L, 1));
	return 0;
}

static const luaL_Reg conslib[] = {
	{ "write", cons_write },
	{ "raw", cons_raw },
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
	unsigned char *p;
	size_t len;

	if (lba < 0)
		return luaL_error(L, "blk.read: negative sector");
	if (nsec <= 0 || nsec > ESP_BLK_MAXSEC)
		return luaL_error(L, "blk.read: bad sector count");

	/* a buffer: the reply gives the sectors away rather than copying
	 * them to the client.
	 */
	len = (size_t)nsec * secsz;
	p = luabuf_push(L, len);
	if (!p)
		return luaL_error(L, "blk.read: no room for %d bytes",
		    (int)len);
	if (esp_blk_read((uint64_t)lba, (uint32_t)nsec, (char *)p) != 0)
		return luaL_error(L, "blk.read: device error");
	return 1;
}

static int
blk_write(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luabuf_check(L, 2, &n);
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

/* ---- los.platform.eth: the radio, as ethernet ----
 *
 * The same four calls virtio-net and SNP give, so task/eth.lua does not
 * know what is under it. Frames only: joining a network is
 * los.platform.wifi below, and a different capability.
 */

static int
eth_mac(lua_State *L)
{
	uint8_t mac[6];

	if (esp_wifi_mac(mac) != 0)
		return 0;
	lua_pushlstring(L, (const char *)mac, sizeof mac);
	return 1;
}

static int
eth_send(lua_State *L)
{
	size_t n;
	const char *data = luabuf_check(L, 1, &n);

	lua_pushboolean(L, esp_wifi_send_frame(data, n) == 0);
	return 1;
}

static int
eth_recv(lua_State *L)
{
	char buf[ESP_WIFI_MAXFRAME];
	size_t n = esp_wifi_recv_frame(buf, sizeof buf);

	if (n == 0)
		return 0;		/* nil: nothing waiting */
	lua_pushlstring(L, buf, n);
	return 1;
}

static int
eth_irqs(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)esp_wifi_irqs());
	return 1;
}

static const luaL_Reg ethlib[] = {
	{ "mac", eth_mac },
	{ "send", eth_send },
	{ "recv", eth_recv },
	{ "irqs", eth_irqs },
	{ NULL, NULL },
};

int luaopen_los_platform_eth(lua_State *L);

int
luaopen_los_platform_eth(lua_State *L)
{
	luaL_newlib(L, ethlib);
	return 1;
}

/* ---- los.platform.gps: the gnss receiver ----
 *
 * Bytes, not sentences: a serial line hands over whatever arrived, and
 * framing belongs to whoever reads it.
 */

/* open(baud) -> ok. Also sets the baud of a port already up, so a
 * caller may try one and then another. Nothing here judges the answer.
 */
static int
gps_open(lua_State *L)
{
	int baud = (int)luaL_optinteger(L, 1, 9600);

	lua_pushboolean(L, esp_gps_open(baud) == 0);
	return 1;
}

static int
gps_read(lua_State *L)
{
	char buf[512];
	int n = esp_gps_read(buf, (int)luaL_optinteger(L, 1, sizeof buf));

	if (n <= 0)
		return 0;		/* nil: nothing waiting */
	lua_pushlstring(L, buf, (size_t)n);
	return 1;
}

static int
gps_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);

	lua_pushinteger(L, esp_gps_write(s, (int)n));
	return 1;
}

static int
gps_stats(lua_State *L)
{
	lua_createtable(L, 0, 1);
	lua_pushinteger(L, (lua_Integer)esp_gps_rx());
	lua_setfield(L, -2, "rx");
	return 1;
}

static const luaL_Reg gpslib[] = {
	{ "open", gps_open },
	{ "read", gps_read },
	{ "write", gps_write },
	{ "stats", gps_stats },
	{ NULL, NULL },
};

int luaopen_los_platform_gps(lua_State *L);

int
luaopen_los_platform_gps(lua_State *L)
{
	luaL_newlib(L, gpslib);
	return 1;
}

/* ---- los.platform.hci: the bluetooth controller ----
 *
 * Whole HCI packets, H4 type byte included, the way a uart transport
 * delivers them. Everything above is lib/ble.
 */

static int
hci_send(lua_State *L)
{
	size_t n;
	const char *data = luabuf_check(L, 1, &n);

	lua_pushboolean(L, esp_ble_send_packet(data, n) == 0);
	return 1;
}

static int
hci_recv(lua_State *L)
{
	char buf[ESP_BLE_MAXPKT];
	size_t n = esp_ble_recv_packet(buf, sizeof buf);

	if (n == 0)
		return 0;		/* nil: nothing waiting */
	lua_pushlstring(L, buf, n);
	return 1;
}

static int
hci_stats(lua_State *L)
{
	lua_newtable(L);
	lua_pushinteger(L, (lua_Integer)esp_ble_irqs());
	lua_setfield(L, -2, "packets");
	lua_pushinteger(L, (lua_Integer)esp_ble_drops());
	lua_setfield(L, -2, "drops");
	lua_pushinteger(L, (lua_Integer)esp_ble_sram_cost());
	lua_setfield(L, -2, "sram");
	return 1;
}

static const luaL_Reg hcilib[] = {
	{ "send", hci_send },
	{ "recv", hci_recv },
	{ "stats", hci_stats },
	{ NULL, NULL },
};

int luaopen_los_platform_hci(lua_State *L);

int
luaopen_los_platform_hci(lua_State *L)
{
	luaL_newlib(L, hcilib);
	return 1;
}

/* ---- los.platform.lora: the radio's wires ----
 *
 * A transfer is bytes out and the same number back, which is what the
 * chip's every command is. lib/sx1262.lua is the chip.
 */

static int
lora_xfer(lua_State *L)
{
	size_t n;
	const char *tx = luabuf_check(L, 1, &n);
	uint8_t rx[64];

	if (n < 1 || n > sizeof rx)
		return luaL_error(L, "lora.xfer: %d bytes", (int)n);
	if (esp_lora_xfer((const uint8_t *)tx, rx, (int)n) != 0)
		return 0;		/* nil: the chip stayed busy */
	lua_pushlstring(L, (const char *)rx, n);
	return 1;
}

static int
lora_reset(lua_State *L)
{
	lua_pushboolean(L, esp_lora_reset() == 0);
	return 1;
}

static int
lora_irq(lua_State *L)
{
	lua_pushboolean(L, esp_lora_irq());
	return 1;
}

static const luaL_Reg loralib[] = {
	{ "xfer", lora_xfer },
	{ "reset", lora_reset },
	{ "irq", lora_irq },
	{ NULL, NULL },
};

int luaopen_los_platform_lora(lua_State *L);

int
luaopen_los_platform_lora(lua_State *L)
{
	luaL_newlib(L, loralib);
	return 1;
}

/* ---- los.platform.wifi: joining a network ----
 *
 * A separate module beside the frames rather than more calls among
 * them, because they are separate concerns: one is a wire, the other is
 * which wire. Both reach the same proc, since the radio is one device
 * and task/eth.lua owns it -- plan 9's ether is likewise the thing you
 * move packets over and the thing you configure.
 */

static int
wifi_connect(lua_State *L)
{
	const char *ssid = luaL_checkstring(L, 1);
	const char *psk = luaL_optstring(L, 2, NULL);

	lua_pushboolean(L, esp_wifi_connect_to(ssid, psk) == 0);
	return 1;
}

static int
wifi_disconnect(lua_State *L)
{
	lua_pushboolean(L, esp_wifi_disconnect_from() == 0);
	return 1;
}

/* state, ssid, reason, drops. The names rather than the numbers: a
 * caller formatting this for someone should not carry the enum.
 */
static int
wifi_status(lua_State *L)
{
	static const char *names[] = { "idle", "joining", "joined", "failed" };
	int reason = 0;
	const char *ssid = NULL;
	int st = esp_wifi_state(&reason, &ssid);

	lua_createtable(L, 0, 5);
	lua_pushstring(L, (st >= 0 && st <= 3) ? names[st] : "unknown");
	lua_setfield(L, -2, "state");
	if (ssid != NULL) {
		lua_pushstring(L, ssid);
		lua_setfield(L, -2, "ssid");
	}
	lua_pushinteger(L, reason);
	lua_setfield(L, -2, "reason");
	lua_pushinteger(L, (lua_Integer)esp_wifi_drops());
	lua_setfield(L, -2, "drops");
	lua_pushboolean(L, esp_wifi_present());
	lua_setfield(L, -2, "up");
	return 1;
}

/* scan_begin starts one; scan_take returns nil while it is still
 * running, so a caller polls instead of blocking the machine.
 */
static int
wifi_scan_begin(lua_State *L)
{
	lua_pushboolean(L, esp_wifi_scan_begin() == 0);
	return 1;
}

#define WIFI_MAXAP 24

static int
wifi_scan_take(lua_State *L)
{
	struct esp_wifi_ap ap[WIFI_MAXAP];
	int n = esp_wifi_scan_take(ap, WIFI_MAXAP);

	if (n < 0) {
		lua_pushnil(L);
		return 1;
	}
	lua_createtable(L, n, 0);
	for (int i = 0; i < n; i++) {
		lua_createtable(L, 0, 4);
		lua_pushstring(L, ap[i].ssid);
		lua_setfield(L, -2, "ssid");
		lua_pushinteger(L, ap[i].rssi);
		lua_setfield(L, -2, "rssi");
		lua_pushboolean(L, ap[i].open);
		lua_setfield(L, -2, "open");
		lua_pushinteger(L, ap[i].channel);
		lua_setfield(L, -2, "channel");
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

static const luaL_Reg wifilib[] = {
	{ "connect", wifi_connect },
	{ "disconnect", wifi_disconnect },
	{ "status", wifi_status },
	{ "scan_begin", wifi_scan_begin },
	{ "scan_take", wifi_scan_take },
	{ NULL, NULL },
};

int luaopen_los_platform_wifi(lua_State *L);

int
luaopen_los_platform_wifi(lua_State *L)
{
	luaL_newlib(L, wifilib);
	return 1;
}

/* ---- los.platform.flash: the data partitions, raw sectors ----
 *
 * The same three calls los.platform.blk gives, so lib/blkfs.lua serves
 * either without knowing which it holds. A sector is 4KB here and 512
 * on the card, which is why nothing above asks for a sector count
 * without asking capacity() first.
 *
 * There is more than one partition, so the three calls are closures
 * over a volume index and flash.volume(i) is what hands out a set of
 * them. The module's own capacity/read/write are volume 1, which is
 * what a caller that knows of only one device gets.
 */

/* the volume a closure was made for. flash.volume() sets it; the
 * module-level calls have it as 0.
 */
static int
flashvol(lua_State *L)
{
	return (int)lua_tointeger(L, lua_upvalueindex(1));
}

static int
flash_capacity(lua_State *L)
{
	int v = flashvol(L);

	if (!esp_flashblk_present(v))
		return 0;		/* nil: no partition */
	lua_pushinteger(L, (lua_Integer)esp_flashblk_sectors(v));
	lua_pushinteger(L, (lua_Integer)esp_flashblk_secsz(v));
	return 2;
}

static int
flash_read(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	lua_Integer nsec = luaL_checkinteger(L, 2);
	int v = flashvol(L);
	uint32_t secsz = esp_flashblk_secsz(v);
	unsigned char *p;
	size_t len;

	if (lba < 0)
		return luaL_error(L, "flash.read: negative sector");
	if (nsec <= 0 || nsec > ESP_FLASHBLK_MAXSEC)
		return luaL_error(L, "flash.read: bad sector count");

	/* a buffer, so the sectors reach whoever asked for them without
	 * being copied on the way: the reply gives them away.
	 */
	len = (size_t)nsec * secsz;
	p = luabuf_push(L, len);
	if (!p)
		return luaL_error(L, "flash.read: no room for %d bytes",
		    (int)len);
	if (esp_flashblk_read(v, (uint64_t)lba, (uint32_t)nsec, (char *)p) != 0)
		return luaL_error(L, "flash.read: device error");
	return 1;
}

static int
flash_write(lua_State *L)
{
	lua_Integer lba = luaL_checkinteger(L, 1);
	size_t n;
	const char *data = luabuf_check(L, 2, &n);
	int v = flashvol(L);
	uint32_t secsz = esp_flashblk_secsz(v);

	if (lba < 0)
		return luaL_error(L, "flash.write: negative sector");
	if (n == 0 || secsz == 0 || n % secsz != 0)
		return luaL_error(L,
		    "flash.write: not a whole number of sectors");
	if (n > (size_t)ESP_FLASHBLK_MAXSEC * secsz)
		return luaL_error(L, "flash.write: too large");
	if (esp_flashblk_write(v, (uint64_t)lba, data, (uint32_t)n) != 0)
		return luaL_error(L, "flash.write: device error");
	lua_pushinteger(L, (lua_Integer)(n / secsz));
	return 1;
}

static const luaL_Reg flash_lib[] = {
	{ "capacity", flash_capacity },
	{ "read", flash_read },
	{ "write", flash_write },
	{ NULL, NULL },
};

/* one volume's three calls, plus maxsec: the shape lib/blkfs.lua takes
 * as a device, so a caller hands it this and the filesystem above never
 * learns which partition it sits on.
 */
static void
pushvolume(lua_State *L, int vol)
{
	const luaL_Reg *f;

	lua_createtable(L, 0, 4);
	for (f = flash_lib; f->name != NULL; f++) {
		lua_pushinteger(L, vol);
		lua_pushcclosure(L, f->func, 1);
		lua_setfield(L, -2, f->name);
	}
	lua_pushinteger(L, ESP_FLASHBLK_MAXSEC);
	lua_setfield(L, -2, "maxsec");
	lua_pushinteger(L, vol + 1);
	lua_setfield(L, -2, "index");	/* which one this is, for a name */
}

/* flash.volume(i) -> a device table, or nil where the partition table
 * has no such partition. 1-based, as every other index a lua caller
 * gives.
 */
static int
flash_volume(lua_State *L)
{
	lua_Integer i = luaL_checkinteger(L, 1);

	if (i < 1 || i > ESP_FLASHBLK_NVOL || !esp_flashblk_present((int)i - 1))
		return 0;
	pushvolume(L, (int)i - 1);
	return 1;
}

/* how many of them this board actually has. A partition table without
 * config answers 1, and the caller serves what is there.
 */
static int
flash_count(lua_State *L)
{
	int n = 0;

	while (n < ESP_FLASHBLK_NVOL && esp_flashblk_present(n))
		n++;
	lua_pushinteger(L, n);
	return 1;
}

int luaopen_los_platform_flash(lua_State *L);

int
luaopen_los_platform_flash(lua_State *L)
{
	/* the module IS volume 1, so a caller holding it reaches luafs
	 * with the same three calls los.platform.blk gives.
	 */
	pushvolume(L, 0);
	lua_pushcfunction(L, flash_volume);
	lua_setfield(L, -2, "volume");
	lua_pushcfunction(L, flash_count);
	lua_setfield(L, -2, "count");
	return 1;
}

/* ---- los.platform.fb: the ST7789, as rectangles ----
 *
 * The same surface efi's GOP backend gives, minus unload: reading
 * pixels back would need either a shadow framebuffer (64800 bytes on a
 * board with none to spare) or ST7789 readback over SPI, which is not
 * reliable. It reports that rather than returning a plausible lie --
 * fb.lua's clients get {err=}, and a layer that needs to save what a
 * window covers will have to keep its own copy.
 */

static void
checkrect(lua_State *L, lua_Integer x, lua_Integer y, lua_Integer w,
    lua_Integer h)
{
	if (x < 0 || y < 0 || w < 0 || h < 0)
		luaL_error(L, "negative rectangle");
	if (x + w > luaos_lcd_width() || y + h > luaos_lcd_height())
		luaL_error(L, "rectangle %dx%d at %d,%d is off a %dx%d screen",
		    (int)w, (int)h, (int)x, (int)y,
		    luaos_lcd_width(), luaos_lcd_height());
}

static void
pushmode(lua_State *L)
{
	lua_createtable(L, 0, 4);
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "n");
	lua_pushinteger(L, luaos_lcd_width());
	lua_setfield(L, -2, "w");
	lua_pushinteger(L, luaos_lcd_height());
	lua_setfield(L, -2, "h");
	/* the panel's own, which load() now takes without converting.
	 * bgrx is still accepted, so a client written against efi works
	 * here unchanged -- it just pays the conversion lcd.c does.
	 */
	lua_pushstring(L, "r5g6b5");
	lua_setfield(L, -2, "format");
}

static int
fb_modes(lua_State *L)
{
	lua_createtable(L, 1, 0);
	pushmode(L);
	lua_rawseti(L, -2, 1);
	return 1;
}

static int
fb_mode(lua_State *L)
{
	pushmode(L);
	return 1;
}

/* one fixed mode: the panel is 240x135 and has no others. */
static int
fb_setmode(lua_State *L)
{
	if (luaL_checkinteger(L, 1) != 0)
		return luaL_error(L, "no such mode");
	return 0;
}

static int
fb_fill(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	lua_Unsigned c = (lua_Unsigned)luaL_checkinteger(L, 5);

	checkrect(L, x, y, w, h);
	if (w == 0 || h == 0)
		return 0;
	if (luaos_lcd_fill((int)x, (int)y, (int)w, (int)h, (uint32_t)c) != 0)
		return luaL_error(L, "fill failed");
	return 0;
}

static int
fb_load(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	size_t n;
	const char *pix = luabuf_check(L, 5, &n);
	const char *fmt = luaL_optstring(L, 6, "bgrx");
	int wide = strcmp(fmt, "r5g6b5") == 0;
	size_t need = (size_t)w * (size_t)h * (wide ? 2 : 4);

	if (!wide && strcmp(fmt, "bgrx") != 0)
		return luaL_error(L, "fb.load: no such format: %s", fmt);
	checkrect(L, x, y, w, h);
	if (n != need)
		return luaL_error(L, "want %d bytes for %dx%d %s, got %d",
		    (int)need, (int)w, (int)h, fmt, (int)n);
	if (need == 0)
		return 0;
	/* r5g6b5 is what the panel takes, so it goes straight down */
	if (wide) {
		if (luaos_lcd_load16((int)x, (int)y, (int)w, (int)h,
		    (const unsigned char *)pix) != 0)
			return luaL_error(L, "load failed");
		return 0;
	}
	if (luaos_lcd_load((int)x, (int)y, (int)w, (int)h,
	    (const unsigned char *)pix) != 0)
		return luaL_error(L, "load failed");
	return 0;
}

/* fb.unload(x,y,w,h [, fmt]) -> the pixels.
 *
 * "bgrx" by default, which is the shared fb protocol's layout and what
 * every drawing client reads. "rgb" is the same pixels with no pad, for
 * a caller writing a file: see luaos_lcd_unload_rgb.
 */
static int
fb_unload(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	const char *fmt = luaL_optstring(L, 5, "bgrx");
	int rgb = strcmp(fmt, "rgb") == 0;
	size_t need = (size_t)w * (size_t)h * (rgb ? 3 : 4);
	luaL_Buffer b;
	char *out;
	int rc;

	if (!rgb && strcmp(fmt, "bgrx") != 0)
		return luaL_error(L, "fb.unload: no such format: %s", fmt);
	checkrect(L, x, y, w, h);
	if (need == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	out = luaL_buffinitsize(L, &b, need);
	rc = rgb ? luaos_lcd_unload_rgb((int)x, (int)y, (int)w, (int)h,
	    (unsigned char *)out)
	    : luaos_lcd_unload((int)x, (int)y, (int)w, (int)h,
	    (unsigned char *)out);
	if (rc != 0)
		return luaL_error(L, "fb.unload: no copy kept -- "
		    "this panel cannot be read, call fb.shadow(true) first");
	luaL_pushresultsize(&b, need);
	return 1;
}


static int
fb_scroll(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer tox = luaL_checkinteger(L, 3);
	lua_Integer toy = luaL_checkinteger(L, 4);
	lua_Integer w = luaL_checkinteger(L, 5);
	lua_Integer h = luaL_checkinteger(L, 6);

	if (luaos_lcd_scroll((int)x, (int)y, (int)tox, (int)toy,
	    (int)w, (int)h) != 0)
		return luaL_error(L, "fb.scroll: this move is unsupported, "
		    "or there is no color copy -- redraw instead");
	lua_pushboolean(L, 1);
	return 1;
}

/* fb.cursor(x, y, on) -- move, show or hide the pointer.
 *
 * Here rather than in whoever tracks the pointer, because this is the
 * only writer to the glass: the cursor is drawn over what is already
 * there and repaired from the colour shadow when anything moves under
 * it, and a second proc drawing it would race every fill. The mouse
 * server reports a position and never draws, exactly as plan 9's
 * devmouse leaves the drawing to devdraw.
 */
static int
fb_cursor(lua_State *L)
{
	lua_Integer x = luaL_optinteger(L, 1, -1);
	lua_Integer y = luaL_optinteger(L, 2, -1);
	int on = lua_isnoneornil(L, 3) ? -1 : (lua_toboolean(L, 3) ? 1 : 0);

	if (luaos_lcd_cursor((int)x, (int)y, on) != 0)
		return luaL_error(L, "fb.cursor: no cursor on this screen");
	lua_pushboolean(L, 1);
	return 1;
}

/* fb.spiprobe(extra, settle) -> refusals. Diagnostic: it builds the
 * transfer backlog a band loop plus a cursor blit leaves and reports
 * whether the completion accounting survives it.
 */
static int
fb_spiprobe(lua_State *L)
{
	lua_Integer extra = luaL_optinteger(L, 1, 1);
	lua_Integer settle = luaL_optinteger(L, 2, 200);
	int n = luaos_lcd_spiprobe((int)extra, (int)settle);

	if (n < 0)
		return luaL_error(L, "fb.spiprobe: no screen here");
	lua_pushinteger(L, n);
	return 1;
}

/* fb.unload1(x,y,w,h) -> packed 1bpp, MSB first.
 *
 * Not part of the shared fb protocol: an efi framebuffer has colour and
 * no bit plane to hand back. task/fb.lua offers the op only where the
 * platform has this, and a screenshot here is the reason -- see lcd.c.
 */
static int
fb_unload1(lua_State *L)
{
	lua_Integer x = luaL_checkinteger(L, 1);
	lua_Integer y = luaL_checkinteger(L, 2);
	lua_Integer w = luaL_checkinteger(L, 3);
	lua_Integer h = luaL_checkinteger(L, 4);
	size_t need;
	luaL_Buffer b;
	char *out;
	int n;

	checkrect(L, x, y, w, h);
	need = (size_t)((w + 7) / 8) * (size_t)h;
	if (need == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	out = luaL_buffinitsize(L, &b, need);
	n = luaos_lcd_unload1((int)x, (int)y, (int)w, (int)h,
	    (unsigned char *)out);
	if (n < 0)
		return luaL_error(L, "fb.unload1: no copy kept -- "
		    "this panel cannot be read, build with "
		    "CONFIG_LUAOS_FB_SHADOW");
	luaL_pushresultsize(&b, (size_t)n);
	return 1;
}

static const luaL_Reg fb_lib[] = {
	{ "modes", fb_modes },
	{ "mode", fb_mode },
	{ "setmode", fb_setmode },
	{ "fill", fb_fill },
	{ "load", fb_load },
	{ "unload", fb_unload },
	{ "unload1", fb_unload1 },
	{ "scroll", fb_scroll },
	{ "cursor", fb_cursor },
	{ "spiprobe", fb_spiprobe },
	{ NULL, NULL },
};

int luaopen_los_platform_fb(lua_State *L);

int
luaopen_los_platform_fb(lua_State *L)
{
	luaL_newlib(L, fb_lib);
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

/* the battery. Only the T-Deck has one wired to a pin we can read, and
 * the charger has no status line -- but it sits across the same
 * divider, so a reading above what a cell can hold is what says the
 * machine is on USB. lib/ps.lua makes that call; this reports volts.
 */
int
platform_battery(int *mv)
{
#if CONFIG_LUAOS_BOARD_TDECK
	int v = esp_tdeck_battery_mv();

	/* under a cell's cutoff means no pack, not a flat one: the
	 * divider floats near zero with nothing attached.
	 */
	if (v < 2500)
		return 0;
	if (mv)
		*mv = v;
	return 1;
#else
	(void)mv;
	return 0;
#endif
}

/* the matrix (Cardputer) or the i2c keyboard (T-Deck), drained by the
 * kernel into a port of its own. Not the console: the serial line stays
 * the console, and this is the input half of the second terminal.
 */
int
platform_have_kbd(void)
{
	return esp_kbd_present();
}

int
platform_kbd_read(void)
{
	int c = esp_kbd_read();

	return c == 0 ? -1 : c;
}

/* the touch panel, as this board's pointer.
 *
 * A finger is one button: there is no hover and no second button to
 * report, so down is button 1 and up is none. What a long press or two
 * fingers should mean is policy, and policy belongs above this in Lua
 * where it can change without a reflash.
 */
int
platform_have_ptr(void)
{
#if CONFIG_LUAOS_BOARD_TDECK
	return esp_touch_present();
#else
	return 0;
#endif
}

int
platform_ptr_read(int *x, int *y, int *buttons)
{
#if CONFIG_LUAOS_BOARD_TDECK
	int down = 0, wheel = 0, ballbtn = 0;

	/* the ball first, because a click is momentary: the panel's
	 * position is still there on the next call and a click is not.
	 */
	if (esp_ball_take(&wheel, &ballbtn)) {
		/* a wheel record carries the pointer's current position,
		 * as plan 9's does -- scrolling happens somewhere.
		 */
		esp_touch_state(x, y, &down);
		if (buttons)
			*buttons = wheel | ballbtn | (down ? 1 : 0);
		return 1;
	}

	if (!esp_touch_take(x, y, &down))
		return 0;
	if (buttons)
		*buttons = down ? 1 : 0;
	return 1;
#else
	(void)x;
	(void)y;
	(void)buttons;
	return 0;
#endif
}

/* no tcp from this machine: it has a wire, and lib/tcp4.lua builds the
 * protocol over the frames. The module is empty, for the link.
 */
int
platform_have_net(void)
{
	return 0;
}

int
platform_net_ready(void)
{
	return 0;
}

int luaopen_los_platform_tcp(lua_State *L);

int
luaopen_los_platform_tcp(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

int
platform_have_udp(void)
{
	return 0;
}

int luaopen_los_platform_udp(lua_State *L);

int
luaopen_los_platform_udp(lua_State *L)
{
	lua_newtable(L);
	return 1;
}

/* no websocket here: this machine has sockets, and lib/websocket.lua
 * builds the framing over one. See PRIV_WS.
 */
int
platform_have_ws(void)
{
	return 0;
}

int luaopen_los_platform_ws(lua_State *L);

int
luaopen_los_platform_ws(lua_State *L)
{
	lua_newtable(L);
	return 1;
}
