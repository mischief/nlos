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

/* T-Deck wiring. From ~/code/c/clm/esp32/firmware/board_tdeck.c and
 * ~/code/pio/tdeck (Pins.h, platformio.ini), which agree on all of it.
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
#define TDECK_RADIO_CS		9
#define TDECK_I2C_SDA		18
#define TDECK_I2C_SCL		8
#define TDECK_KB_ADDR		0x55	/* the keyboard is its own C3 */
#define TDECK_KB_INT		46

/* the largest single SPI transfer any T-Deck driver asks for. A display
 * band dwarfs the card's 32-sector read, so this is the display's.
 */
#define TDECK_SPI_MAXXFER	(320 * 16 * 2)

/* raise the peripheral power rail. Idempotent, and it sleeps 500ms the
 * first time: the keyboard's own microcontroller boots off this rail.
 * Miss it and the card, the panel and the keyboard all read as absent.
 */
int	esp_tdeck_power_on(void);

/* bring up the shared SPI bus, powering the rail first. Idempotent, so
 * whichever of blk and lcd probes first pays for it.
 */
int	esp_tdeck_spi_init(void);

#endif

#endif
