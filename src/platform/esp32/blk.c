/* the T-Deck's microSD slot as whole-disk sectors.
 *
 * Deliberately NOT esp_vfs_fat_sdspi_mount, which is what every esp32
 * project reaches for (the esp32-torrent and clm firmwares both
 * do). That mounts FAT behind IDF's VFS and hands back a POSIX path.
 * What lua-os wants is one layer below it: sdmmc_card_init plus
 * sdmmc_read_sectors/sdmmc_write_sectors, which is exactly the surface
 * EFI_BLOCK_IO gives on efi and virtio_blk gives on microvm. lib/gpt.lua
 * parses the partition table and lib/gefs is the filesystem, both
 * unchanged -- so the card is readable by the same code as a disk, and
 * a card partitioned on the desktop is a test of the whole stack.
 */

#include <stdio.h>
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

#include "platform.h"
#include "esp32.h"
#include "blk.h"

/* the wiring, the power rail and the shared SPI bus all live in
 * esp32.h and tdeck.c: the display and the LoRa radio are on this same
 * bus, so whichever driver probes first brings it up.
 */

/* 20MHz asked for, not clamped down to. Asking high reaches 20 only on
 * a card that declines it; one that accepts takes IDF's CMD6 path,
 * where a U3/V30 card failed with ESP_ERR_INVALID_RESPONSE from
 * send_csd. The bus is not the limit: the display runs at 60MHz here.
 */
#define TDECK_SD_FREQ_KHZ	SDMMC_FREQ_DEFAULT

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

int
esp_blk_present(void)
{
	sdmmc_host_t host = SDSPI_HOST_DEFAULT();
	sdspi_device_config_t slot = SDSPI_DEVICE_CONFIG_DEFAULT();
	sdspi_dev_handle_t dev;

	if (probed)
		return present;
	probed = 1;

	if (esp_tdeck_spi_init() != 0)
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

	/* say what answered, the way kbd does. A capacity cannot be
	 * guessed -- it comes back from the card's own CSD, so printing
	 * it is evidence the card enumerated rather than that the pins
	 * were configured. Without it "blksrv: pid 2" is equally true of
	 * a driver that found nothing and a card that is really there.
	 */
	{
		char m[96];
		unsigned long long mb = (unsigned long long)card.csd.capacity *
		    card.csd.sector_size / (1024 * 1024);
		int khz = 0;
		int n;

		/* the negotiated rate, which is the card's answer and not
		 * the request above: a high-speed card takes 40MHz and one
		 * that is not clamps itself, and only this says which.
		 */
		if (sdspi_host_get_real_freq(dev, &khz) != ESP_OK)
			khz = 0;
		n = snprintf(m, sizeof m,
		    "blk: %lluMB, %d sectors of %d bytes, %dkHz\n", mb,
		    card.csd.capacity, card.csd.sector_size, khz);

		console_write(m, (size_t)n);
	}

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
