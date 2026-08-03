/* raw block i/o over EFI_BLOCK_IO_PROTOCOL, the efi side of what
 * virtio_blk is on microvm. Whole-disk sectors and a capacity; the GPT
 * and the filesystem above are lib/gpt.lua and lib/gefs, unchanged.
 */
#ifndef EFI_BLK_H
#define EFI_BLK_H

#include <stdint.h>

int efi_blk_present(void);		/* find a whole disk; cache it */
uint64_t efi_blk_sectors(void);		/* device capacity in sectors */
uint32_t efi_blk_secsz(void);		/* bytes per sector */
int efi_blk_read(uint64_t lba, uint32_t nsec, void *buf);	/* 0 ok */
int efi_blk_write(uint64_t lba, const void *buf, uint32_t nbytes); /* 0 ok */

#endif
