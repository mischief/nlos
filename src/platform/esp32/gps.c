/* the gnss receiver on a T-Deck Plus, as bytes. Sentences are framed
 * above: a serial line hands over whatever arrived, and one sentence
 * spans two reads as often as not. The module owns the pins the Grove
 * connector carries, which is why the console cannot. An L76K runs at
 * 9600 and a u-blox M10Q at 38400, so the baud is settable, not fixed.
 */

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/uart.h>
#include <esp_err.h>
#include <string.h>

#include "esp32.h"

/* UART1: 0 is the rom bootloader's and the usb console's fallback. */
#define GPSUART		UART_NUM_1

/* a second of a chatty receiver at 38400, so a reader that misses a
 * lap loses nothing and one that stops losing is bounded
 */
#define RXBUF		4096

/* one read's worth, so a drain cannot hold the machine */
#define CHUNK		512

static int up;
static unsigned long rxbytes;

/* Bring the port up at `baud`, first call or later. A receiver whose
 * baud is wrong answers with framing noise rather than silence, so
 * changing it is how the caller probes and must not lose the driver.
 */
int
esp_gps_open(int baud)
{
	uart_config_t cfg = {
		.baud_rate = baud > 0 ? baud : 9600,
		.data_bits = UART_DATA_8_BITS,
		.parity = UART_PARITY_DISABLE,
		.stop_bits = UART_STOP_BITS_1,
		.flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
		.source_clk = UART_SCLK_DEFAULT,
	};

	if (esp_tdeck_power_on() != 0)
		return -1;

	if (up) {
		return uart_set_baudrate(GPSUART, cfg.baud_rate) == ESP_OK ?
		    0 : -1;
	}

	if (uart_driver_install(GPSUART, RXBUF, 0, 0, NULL, 0) != ESP_OK)
		return -1;
	if (uart_param_config(GPSUART, &cfg) != ESP_OK ||
	    uart_set_pin(GPSUART, TDECK_GPS_TX, TDECK_GPS_RX,
	    UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE) != ESP_OK) {
		uart_driver_delete(GPSUART);
		return -1;
	}
	up = 1;
	return 0;
}

/* what is waiting, up to n bytes, and never a wait: this runs on the
 * task that is the machine, so blocking here blocks everything.
 */
int
esp_gps_read(char *out, int n)
{
	int got;

	if (!up || n <= 0)
		return 0;
	if (n > CHUNK)
		n = CHUNK;
	got = uart_read_bytes(GPSUART, (uint8_t *)out, n, 0);
	if (got <= 0)
		return 0;
	rxbytes += (unsigned long)got;
	return got;
}

/* the other direction, for the sentences that configure a receiver
 * rather than report from one.
 */
int
esp_gps_write(const char *s, int n)
{
	if (!up || n <= 0)
		return 0;
	return uart_write_bytes(GPSUART, s, (size_t)n);
}

unsigned long
esp_gps_rx(void)
{
	return rxbytes;
}

/* present where the board could carry one. Whether a module is fitted
 * is settled only by what it answers: a plain T-Deck leaves these pins
 * on the Grove header with nothing driving them, and silence is the
 * report rather than a failure to start.
 */
int
platform_have_gps(void)
{
	return 1;
}

unsigned long
platform_gps_rx(void)
{
	return rxbytes;
}

unsigned long
platform_gps_pending(void)
{
	size_t n = 0;

	if (!up || uart_get_buffered_data_len(GPSUART, &n) != ESP_OK)
		return 0;
	return (unsigned long)n;
}

#else	/* not a T-Deck */

int	esp_gps_open(int baud);
int	esp_gps_read(char *out, int n);
int	esp_gps_write(const char *s, int n);
unsigned long esp_gps_rx(void);

int
esp_gps_open(int baud)
{
	(void)baud;
	return -1;
}

int
esp_gps_read(char *out, int n)
{
	(void)out;
	(void)n;
	return 0;
}

int
esp_gps_write(const char *s, int n)
{
	(void)s;
	(void)n;
	return 0;
}

unsigned long
esp_gps_rx(void)
{
	return 0;
}

int
platform_have_gps(void)
{
	return 0;
}

unsigned long
platform_gps_rx(void)
{
	return 0;
}

unsigned long
platform_gps_pending(void)
{
	return 0;
}

#endif
