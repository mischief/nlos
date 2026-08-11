/* the two things every T-Deck peripheral needs before it exists: the
 * switched power rail, and the SPI bus they all share.
 *
 * Both are shared state, which is why they are here rather than in the
 * driver that happens to run first. The display, the microSD and the
 * LoRa radio hang off one bus, and the display, the keyboard and the
 * card sit behind one power gate -- so whichever of blk.c and lcd.c
 * probes first does the work and the other must not redo it. Getting
 * that wrong is not subtle: a second spi_bus_initialize fails the whole
 * probe, and a missed power rail makes every device look absent.
 *
 * Wiring from clm's esp32 firmware (board_tdeck.c) and the LilyGo
 * reference sketch (Pins.h and platformio.ini), which agree.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/gpio.h>
#include <driver/i2c_master.h>
#include <driver/spi_common.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "esp32.h"

static int powered;
static int bused;
static int i2ced;
static i2c_master_bus_handle_t i2cbus;

int
esp_tdeck_power_on(void)
{
	gpio_config_t pwr = {
		.pin_bit_mask = 1ULL << TDECK_POWERON_GPIO,
		.mode = GPIO_MODE_OUTPUT,
	};

	if (powered)
		return 0;
	if (gpio_config(&pwr) != ESP_OK)
		return -1;
	if (gpio_set_level(TDECK_POWERON_GPIO, 1) != ESP_OK)
		return -1;

	/* the rail feeds the card, the display and the keyboard's own
	 * C3, which has to boot before it answers over i2c. clm waits
	 * 500ms; the cost is paid once at boot.
	 */
	vTaskDelay(pdMS_TO_TICKS(500));
	powered = 1;
	return 0;
}

int
esp_tdeck_spi_init(void)
{
	gpio_config_t cs = {
		.pin_bit_mask = (1ULL << TDECK_SD_CS) |
		    (1ULL << TDECK_TFT_CS) | (1ULL << TDECK_RADIO_CS),
		.mode = GPIO_MODE_OUTPUT,
	};
	spi_bus_config_t bus = {
		.mosi_io_num = TDECK_SPI_MOSI,
		.miso_io_num = TDECK_SPI_MISO,
		.sclk_io_num = TDECK_SPI_SCK,
		.quadwp_io_num = -1,
		.quadhd_io_num = -1,
		/* one figure for the bus, not the caller's own need: the
		 * first driver to probe is the one that sets it, so a
		 * per-caller size would mean the display's ceiling
		 * depended on whether the card was present. Sized for the
		 * larger of the two -- a display band -- which covers the
		 * card's 32-sector read as well.
		 */
		.max_transfer_sz = TDECK_SPI_MAXXFER,
	};

	if (bused)
		return 0;
	if (esp_tdeck_power_on() != 0)
		return -1;

	/* every chip select high before the bus comes up, or a second
	 * peripheral answers over the one being addressed.
	 */
	if (gpio_config(&cs) != ESP_OK)
		return -1;
	gpio_set_level(TDECK_SD_CS, 1);
	gpio_set_level(TDECK_TFT_CS, 1);
	gpio_set_level(TDECK_RADIO_CS, 1);

	if (spi_bus_initialize(TDECK_SPI_HOST, &bus, SPI_DMA_CH_AUTO) !=
	    ESP_OK)
		return -1;
	bused = 1;
	return 0;
}

/* the i2c bus, shared the way the spi one above is.
 *
 * The keyboard's C3 is at 0x55 and the touch controller at 0x5d, on
 * the same two pins. i2c_new_master_bus fails for the second caller,
 * so a driver creating its own bus works only if it is the one that
 * runs first -- and which that is depends on probe order, which is why
 * this is here and not in whichever driver got here first.
 *
 * Hands back the bus rather than a device: an address is the caller's
 * business, the wires are not.
 */
int
esp_tdeck_i2c(i2c_master_bus_handle_t *out)
{
	i2c_master_bus_config_t cfg = {
		.i2c_port = -1,
		.sda_io_num = TDECK_I2C_SDA,
		.scl_io_num = TDECK_I2C_SCL,
		.clk_source = I2C_CLK_SRC_DEFAULT,
		.glitch_ignore_cnt = 7,
		.flags.enable_internal_pullup = true,
	};

	if (!i2ced) {
		/* the keyboard's controller and the touch panel both sit
		 * behind the switched rail, so it goes up first.
		 */
		if (esp_tdeck_power_on() != 0)
			return -1;
		if (i2c_new_master_bus(&cfg, &i2cbus) != ESP_OK)
			return -1;
		i2ced = 1;
	}
	if (out)
		*out = i2cbus;
	return 0;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */

/* the gpio interrupt service, installed once. Three drivers here want a
 * pin interrupt and IDF logs the second and third installs as errors,
 * which is a fault in the log and not in the machine.
 */
int
esp_gpio_isr(void)
{
	static int done;
	esp_err_t e;

	if (done)
		return 0;

	e = gpio_install_isr_service(0);
	if (e != ESP_OK && e != ESP_ERR_INVALID_STATE)
		return -1;
	done = 1;
	return 0;
}
