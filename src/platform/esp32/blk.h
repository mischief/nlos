/* raw block i/o over the T-Deck's microSD slot, the esp32 side of what
 * EFI_BLOCK_IO is on efi and virtio_blk is on microvm. Whole-disk
 * sectors and a capacity; the GPT and the filesystem above are
 * lib/gpt.lua and lib/gefs, unchanged.
 */
#ifndef ESP32_BLK_H
#define ESP32_BLK_H

#include <stdint.h>

/* One transfer's ceiling, in the spirit of efi's EFI_BLK_MAXSEC and
 * microvm's VIRTIO_BLK_MAXIO: bound what a call moves rather than trust
 * the count. lib/blkfs.lua splits larger reads itself and never asks
 * for more than its own 32-sector step. It also sizes the staging
 * buffer in blk.c, so raising it costs internal SRAM.
 */
#define ESP_BLK_MAXSEC 32

int esp_blk_present(void);		/* probe once at boot; cache it */
uint64_t esp_blk_sectors(void);		/* device capacity in sectors */
uint32_t esp_blk_secsz(void);		/* bytes per sector */
int esp_blk_read(uint64_t lba, uint32_t nsec, void *buf);	/* 0 ok */
int esp_blk_write(uint64_t lba, const void *buf, uint32_t nbytes); /* 0 ok */

#endif
