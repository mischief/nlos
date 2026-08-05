/* the T-Deck's microSD slot as whole-disk sectors.
 *
 * Deliberately NOT esp_vfs_fat_sdspi_mount, which is what every esp32
 * project reaches for (~/code/pio/esp32-torrent and ~/code/c/clm both
 * do). That mounts FAT behind IDF's VFS and hands back a POSIX path.
 * What lua-os wants is one layer below it: sdmmc_card_init plus
 * sdmmc_read_sectors/sdmmc_write_sectors, which is exactly the surface
 * EFI_BLOCK_IO gives on efi and virtio_blk gives on microvm. lib/gpt.lua
 * parses the partition table and lib/gefs is the filesystem, both
 * unchanged -- so the card is readable by the same code as a disk, and
 * a card partitioned on the desktop is a test of the whole stack.
 */

#include <string.h>

#include <sdkconfig.h>

#if CONFIG_LUAOS_BOARD_TDECK

#include <driver/gpio.h>
#include <driver/sdspi_host.h>
#include <driver/spi_common.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <sdmmc_cmd.h>

#include "blk.h"

/* T-Deck wiring, from ~/code/c/clm/esp32/firmware/board_tdeck.c, which
 * is the tested source for this board. One SPI bus is shared by the SD
 * card, the display and the LoRa radio, so every chip select has to be
 * driven high before the bus comes up or a second peripheral answers
 * over the card.
 */
#define TDECK_POWERON_GPIO	10	/* the peripheral power rail */
#define TDECK_SPI_SCK		40
#define TDECK_SPI_MISO		38
#define TDECK_SPI_MOSI		41
#define TDECK_SD_CS		39
#define TDECK_TFT_CS		12
#define TDECK_RADIO_CS		9

/* Conservative on purpose. clm settles at 800kHz with the note that the
 * shared bus is fussy, and a card that enumerates but corrupts under
 * load is a far worse first result than a slow one. Raising this is a
 * follow-up with a read/write test behind it, not a guess.
 */
#define TDECK_SD_FREQ_KHZ	800

static sdmmc_card_t card;
static int probed;		/* probe ran; present says what it found */
static int present;

/* A DMA-capable staging buffer, because the caller's is not.
 *
 * sdmmc_read_sectors copes with any buffer, but the way it copes is to
 * fall back to one single-block transfer at a time through a temporary
 * of its own -- and lua's buffers come from luaheap, whose chunks are in
 * PSRAM on this board, so that slow path would be every read. Staging
 * through one internal-SRAM buffer keeps multi-block transfers whole and
 * costs a memcpy.
 */
static void *dma;

static int
board_power_on(void)
{
	gpio_config_t pwr = {
		.pin_bit_mask = 1ULL << TDECK_POWERON_GPIO,
		.mode = GPIO_MODE_OUTPUT,
	};

	if (gpio_config(&pwr) != ESP_OK)
		return -1;
	if (gpio_set_level(TDECK_POWERON_GPIO, 1) != ESP_OK)
		return -1;

	/* the rail feeds the card, the display and the keyboard's own
	 * C3, which has to boot before it answers. clm waits 500ms and
	 * so do we; this runs once, at probe.
	 */
	vTaskDelay(pdMS_TO_TICKS(500));
	return 0;
}

static int
bus_init(void)
{
	gpio_config_t cs = {
		.pin_bit_mask = (1ULL << TDECK_SD_CS) | (1ULL << TDECK_TFT_CS) |
		    (1ULL << TDECK_RADIO_CS),
		.mode = GPIO_MODE_OUTPUT,
	};
	spi_bus_config_t bus = {
		.mosi_io_num = TDECK_SPI_MOSI,
		.miso_io_num = TDECK_SPI_MISO,
		.sclk_io_num = TDECK_SPI_SCK,
		.quadwp_io_num = -1,
		.quadhd_io_num = -1,
		.max_transfer_sz = ESP_BLK_MAXSEC * 512,
	};

	if (gpio_config(&cs) != ESP_OK)
		return -1;

	/* deselect all three before the bus exists, so only the card
	 * answers once it does.
	 */
	gpio_set_level(TDECK_SD_CS, 1);
	gpio_set_level(TDECK_TFT_CS, 1);
	gpio_set_level(TDECK_RADIO_CS, 1);

	if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK)
		return -1;
	return 0;
}

int
esp_blk_present(void)
{
	sdmmc_host_t host = SDSPI_HOST_DEFAULT();
	sdspi_device_config_t slot = SDSPI_DEVICE_CONFIG_DEFAULT();
	sdspi_dev_handle_t dev;

	if (probed)
		return present;
	probed = 1;

	if (board_power_on() != 0 || bus_init() != 0)
		return 0;

	host.slot = SPI2_HOST;
	host.max_freq_khz = TDECK_SD_FREQ_KHZ;

	slot.gpio_cs = TDECK_SD_CS;
	slot.host_id = SPI2_HOST;

	if (sdspi_host_init() != ESP_OK)
		return 0;
	if (sdspi_host_init_device(&slot, &dev) != ESP_OK)
		return 0;

	/* the handle from init_device replaces the host id in slot --
	 * sdmmc_card_init addresses the device, not the bus.
	 */
	host.slot = dev;

	if (sdmmc_card_init(&host, &card) != ESP_OK)
		return 0;

	dma = heap_caps_malloc(ESP_BLK_MAXSEC * card.csd.sector_size,
	    MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
	if (dma == NULL)
		return 0;

	present = 1;
	return 1;
}

uint64_t
esp_blk_sectors(void)
{
	return present ? (uint64_t)card.csd.capacity : 0;
}

uint32_t
esp_blk_secsz(void)
{
	return present ? (uint32_t)card.csd.sector_size : 0;
}

int
esp_blk_read(uint64_t lba, uint32_t nsec, void *buf)
{
	if (!present || nsec == 0 || nsec > ESP_BLK_MAXSEC)
		return -1;
	if (sdmmc_read_sectors(&card, dma, (size_t)lba, (size_t)nsec) != ESP_OK)
		return -1;
	memcpy(buf, dma, (size_t)nsec * card.csd.sector_size);
	return 0;
}

int
esp_blk_write(uint64_t lba, const void *buf, uint32_t nbytes)
{
	uint32_t secsz = present ? (uint32_t)card.csd.sector_size : 0;
	uint32_t nsec;

	if (!present || secsz == 0 || nbytes == 0 || nbytes % secsz != 0)
		return -1;
	nsec = nbytes / secsz;
	if (nsec > ESP_BLK_MAXSEC)
		return -1;

	memcpy(dma, buf, nbytes);
	if (sdmmc_write_sectors(&card, dma, (size_t)lba, (size_t)nsec) != ESP_OK)
		return -1;
	return 0;
}

#else /* !CONFIG_LUAOS_BOARD_TDECK */

/* No SD wiring for this board, so the probe must not touch a bus.
 *
 * This is the whole reason CONFIG_LUAOS_BOARD exists: the T-Deck probe
 * powers a rail and initialises SPI2, and under qemu -- which emulates
 * neither -- it never returns. The machine hung after "lua-os on esp32"
 * and before cons, so every boot test timed out with no plan. A probe
 * that cannot answer "no" quickly is worse than one that answers wrong.
 */
int
esp_blk_present(void)
{
	return 0;
}

uint64_t
esp_blk_sectors(void)
{
	return 0;
}

uint32_t
esp_blk_secsz(void)
{
	return 0;
}

int
esp_blk_read(uint64_t lba, uint32_t nsec, void *buf)
{
	(void)lba;
	(void)nsec;
	(void)buf;
	return -1;
}

int
esp_blk_write(uint64_t lba, const void *buf, uint32_t nbytes)
{
	(void)lba;
	(void)buf;
	(void)nbytes;
	return -1;
}

#endif /* CONFIG_LUAOS_BOARD_TDECK */
