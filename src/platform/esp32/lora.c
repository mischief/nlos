/* the T-Deck's SX1262, as wires and nothing else.
 *
 * A command is an opcode and its bytes, and the chip answers over the
 * same transfer. What the opcodes mean is lib/sx1262.lua's business,
 * the way lib/ble owns everything above the HCI packets here.
 */

/* BUSY is the whole protocol at this level: the chip raises it while it
 * works, and a transfer started before it drops reads the last answer
 * again. Every command waits for it, so a caller above never sees it.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <stdio.h>
#include <string.h>

#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "esp32.h"
#include "kernel.h"
#include "lora.h"

/* 8MHz: the chip takes 16, and the bus is shared with a display whose
 * traces are longer. Nothing here is a throughput path -- the radio's
 * own air rate is thousands of times slower than the wire to it.
 */
#define LORA_HZ		(8 * 1000 * 1000)
#define BUSY_MS		20

static spi_device_handle_t dev;
static int probed, present;

/* the chip works with BUSY high and answers stale bytes until it
 * drops. A timeout here means the wires are wrong, not that it is slow.
 */
static int
waitbusy(void)
{
	int i;

	for (i = 0; i < BUSY_MS * 10; i++) {
		if (gpio_get_level(TDECK_RADIO_BUSY) == 0)
			return 0;
		esp_rom_delay_us(100);
	}
	return -1;
}

/* one transfer: the opcode and its arguments out, the same number of
 * bytes back. A command that answers nothing passes rx as NULL.
 */
int
esp_lora_xfer(const uint8_t *tx, uint8_t *rx, int n)
{
	spi_transaction_t t = { 0 };

	if (!dev || n <= 0 || n > 64)
		return -1;
	if (waitbusy() != 0)
		return -1;

	t.length = n * 8;
	t.tx_buffer = tx;
	t.rx_buffer = rx;
	t.rxlength = rx ? n * 8 : 0;

	gpio_set_level(TDECK_RADIO_CS, 0);

	esp_err_t e = spi_device_polling_transmit(dev, &t);

	gpio_set_level(TDECK_RADIO_CS, 1);
	return e == ESP_OK ? 0 : -1;
}

/* NRESET is active low and the chip wants 100us of it; the datasheet's
 * own figure. Afterwards it walks itself through its boot and raises
 * BUSY until it is done.
 */
static int
reset(void)
{
	gpio_set_level(TDECK_RADIO_RST, 0);
	vTaskDelay(pdMS_TO_TICKS(2));
	gpio_set_level(TDECK_RADIO_RST, 1);
	vTaskDelay(pdMS_TO_TICKS(20));
	return waitbusy();
}

/* ReadRegister: opcode, address, a status byte the chip returns while
 * it is still fetching, then the data.
 */
static int
readreg(uint16_t addr, uint8_t *out, int n)
{
	uint8_t tx[4 + 16] = { 0x1d, (uint8_t)(addr >> 8), (uint8_t)addr, 0 };
	uint8_t rx[4 + 16];

	if (n < 1 || n > 16)
		return -1;
	if (esp_lora_xfer(tx, rx, 4 + n) != 0)
		return -1;
	memcpy(out, rx + 4, n);
	return 0;
}

static int
writereg(uint16_t addr, const uint8_t *in, int n)
{
	uint8_t tx[3 + 16] = { 0x0d, (uint8_t)(addr >> 8), (uint8_t)addr };

	if (n < 1 || n > 16)
		return -1;
	memcpy(tx + 3, in, n);
	return esp_lora_xfer(tx, NULL, 3 + n);
}

/* is there a radio, and does it answer both ways?
 *
 * The sync word is the register to ask: it has a known value out of
 * reset, and it is ours to change -- so writing it and reading it back
 * proves the bus in both directions without disturbing anything.
 */
int
esp_lora_present(void)
{
	spi_device_interface_config_t cfg = {
		.clock_speed_hz = LORA_HZ,
		.mode = 0,
		.spics_io_num = -1,	/* driven here, around BUSY */
		.queue_size = 1,
	};
	gpio_config_t pins = {
		.pin_bit_mask = (1ULL << TDECK_RADIO_RST),
		.mode = GPIO_MODE_OUTPUT,
	};
	gpio_config_t busy = {
		.pin_bit_mask = (1ULL << TDECK_RADIO_BUSY) |
		    (1ULL << TDECK_RADIO_DIO1),
		.mode = GPIO_MODE_INPUT,
	};
	uint8_t was[2], want[2] = { 0x34, 0x44 }, back[2];
	char m[80];

	if (probed)
		return present;
	probed = 1;

	if (esp_tdeck_spi_init() != 0) {
		kernel_log("lora: no spi bus");
		return 0;
	}
	if (gpio_config(&pins) != ESP_OK || gpio_config(&busy) != ESP_OK) {
		kernel_log("lora: cannot claim the reset and busy pins");
		return 0;
	}
	gpio_set_level(TDECK_RADIO_RST, 1);

	if (spi_bus_add_device(TDECK_SPI_HOST, &cfg, &dev) != ESP_OK) {
		kernel_log("lora: cannot attach to the spi bus");
		dev = NULL;
		return 0;
	}

	if (reset() != 0) {
		kernel_log("lora: busy never dropped after reset");
		return 0;
	}

	/* out of reset this is the private-network sync word, 0x1424 */
	if (readreg(0x0740, was, 2) != 0) {
		kernel_log("lora: the sync word would not read");
		return 0;
	}

	if (writereg(0x0740, want, 2) != 0 ||
	    readreg(0x0740, back, 2) != 0) {
		kernel_log("lora: the sync word would not write");
		return 0;
	}
	if (back[0] != want[0] || back[1] != want[1]) {
		snprintf(m, sizeof m,
		    "lora: wrote %02x%02x, read %02x%02x -- not a sx1262?",
		    want[0], want[1], back[0], back[1]);
		kernel_log(m);
		return 0;
	}
	writereg(0x0740, was, 2);

	snprintf(m, sizeof m, "lora: sx1262 answers, sync word %02x%02x",
	    was[0], was[1]);
	kernel_log(m);
	present = 1;
	return 1;
}

#else

int
esp_lora_present(void)
{
	return 0;
}

int
esp_lora_xfer(const uint8_t *tx, uint8_t *rx, int n)
{
	(void)tx;
	(void)rx;
	(void)n;
	return -1;
}

#endif
