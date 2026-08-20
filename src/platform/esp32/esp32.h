#ifndef ESP32_H
#define ESP32_H

/* esp32-local platform bits, kept out of src/platform.h because no
 * other platform has an opinion about them.
 */

/* set up the IDF console for the way kernel.c uses it: unbuffered, and
 * non-blocking on input, because pump_serial polls rather than parks.
 */
void	console_init(void);

/* is a byte already there? The idle path needs to distinguish "nothing
 * to do, sleep until the tick" from "a key arrived", and console_getchar
 * would consume the byte it is asking about. Buffers one character.
 */
int	console_peek(void);

/* pass bytes through untranslated. See console.c: the \n -> \r\n
 * rewrite corrupts any binary stream carrying 0x0a, which is what
 * task/cons.lua's rawon exists to turn off.
 */
void	console_setraw(int on);

/* publish the embedded set to newlib's fopen, which is what lua's
 * luaL_loadfile and the path searcher use. See vfs.c for why this is
 * needed here and on no other platform.
 */
void	vfs_embed_register(void);

#if CONFIG_LUAOS_BOARD_TDECK

/* T-Deck wiring. From clm's esp32 firmware (board_tdeck.c) and the
 * LilyGo reference sketch (Pins.h, platformio.ini), which agree on all
 * of it.
 * Here rather than in one driver because the bus and the power rail are
 * shared: the display, the microSD and the LoRa radio are on one SPI,
 * and the display, the card and the keyboard behind one power gate.
 */
#define TDECK_POWERON_GPIO	10
#define TDECK_SPI_HOST		SPI2_HOST
#define TDECK_SPI_SCK		40
#define TDECK_SPI_MISO		38
#define TDECK_SPI_MOSI		41
#define TDECK_SD_CS		39
#define TDECK_TFT_CS		12
#define TDECK_TFT_DC		11
#define TDECK_TFT_BL		42
/* the SX1262, fourth device on the shared spi bus. BUSY is the one
 * that matters: the chip takes its own time over a command and reading
 * it before the pin drops gets the previous answer.
 */
#define TDECK_RADIO_CS		9
#define TDECK_RADIO_BUSY	13
#define TDECK_RADIO_RST		17
#define TDECK_RADIO_DIO1	45
#define TDECK_I2C_SDA		18
#define TDECK_I2C_SCL		8
#define TDECK_KB_ADDR		0x55	/* the keyboard is its own C3 */
#define TDECK_KB_INT		46
#define TDECK_TOUCH_ADDR	0x5d	/* GT911, the second device on i2c */
#define TDECK_TOUCH_INT		16
#define TDECK_BAT_ADC		4	/* the pack, behind a 2:1 divider */
/* the amplifier. No enable of its own: it comes up with the peripheral
 * rail TDECK_POWERON_GPIO raises.
 */
#define TDECK_I2S_BCK		7
#define TDECK_I2S_WS		5
#define TDECK_I2S_DOUT		6

/* the gnss module on a Plus, on the pins a plain T-Deck leaves on the
 * Grove header. Named from this end: the receiver's own TX reaches
 * TDECK_GPS_RX. U0TXD is GPIO43, so a board carrying a module has no
 * console on these pins.
 */
#define TDECK_GPS_TX		43
#define TDECK_GPS_RX		44

/* the largest single SPI transfer any T-Deck driver asks for. A display
 * band dwarfs the card's 32-sector read, so this is the display's.
 */
#define TDECK_SPI_MAXXFER	(320 * 16 * 2)

/* raise the peripheral power rail. Idempotent, and it sleeps 500ms the
 * first time: the keyboard's own microcontroller boots off this rail.
 * Miss it and the card, the panel and the keyboard all read as absent.
 */
int	esp_tdeck_power_on(void);

/* the gnss receiver, in gps.c. open() also sets the baud of a port
 * already up: a receiver at the wrong one answers with noise rather
 * than silence, so trying is the only way to tell which is fitted.
 */
int	esp_gps_open(int baud);
int	esp_gps_read(char *out, int n);
int	esp_gps_write(const char *s, int n);
unsigned long esp_gps_rx(void);

/* bring up the shared SPI bus, powering the rail first. Idempotent, so
 * whichever of blk and lcd probes first pays for it.
 */
int	esp_tdeck_spi_init(void);

/* the shared i2c bus, on the same terms: the keyboard at 0x55 and the
 * touch controller at 0x5d are on one pair of pins, and only the first
 * caller may create it. Powers the rail first, since both devices are
 * behind it. Fills *out with the bus; a caller adds its own address.
 */
struct i2c_master_bus_t;
int	esp_tdeck_i2c(struct i2c_master_bus_t **out);

/* the pack voltage in millivolts, or 0 if the ADC would not answer.
 * Doubled for the divider, and calibrated where the chip carries the
 * factory curve. Costs a few milliseconds, so a caller polls it slowly.
 */
int	esp_tdeck_battery_mv(void);

/* the gpio interrupt service, installed once for every driver here */
int	esp_gpio_isr(void);


#endif

#endif
