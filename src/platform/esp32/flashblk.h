/* the flash data partitions as raw sectors, the same surface blk.h
 * gives for the microSD slot. lib/blkfs.lua turns either into /data and
 * lib/fat sits above, knowing about neither.
 *
 * A volume is an index into the partition table this knows about:
 * 0 is luafs, 1 is config. They are separate devices with separate
 * sector spaces, so nothing above can reach one through the other.
 *
 * A sector here is one flash erase block, not 512 bytes. NOR flash
 * erases in 4KB units and cannot rewrite a byte without erasing what
 * holds it, so a 512-byte sector would make every write a read, an
 * erase and a program of the whole 4KB around it. Matching the two
 * makes a sector write exactly one erase and one program. FAT accepts
 * 4096-byte sectors -- see the bytspersec check in lib/fat/vol.lua --
 * so the geometry does the work that a wear levelling layer would
 * otherwise have to.
 */
#ifndef ESP32_FLASHBLK_H
#define ESP32_FLASHBLK_H

#include <stdint.h>

/* One transfer's ceiling, as in blk.h. Eight 4KB sectors is 32KB, and
 * unlike the microSD path this one needs no staging buffer: the
 * partition API reads straight into the caller's memory.
 */
#define ESP_FLASHBLK_MAXSEC 8

/* how many volumes this knows names for. A board whose table has only
 * luafs answers present() false for the rest, which is the case an
 * older partition table gives.
 */
#define ESP_FLASHBLK_NVOL 2

int esp_flashblk_present(int vol);	/* found the partition; cached */
uint64_t esp_flashblk_sectors(int vol);	/* partition size in sectors */
uint32_t esp_flashblk_secsz(int vol);	/* bytes per sector: the erase block */
int esp_flashblk_read(int vol, uint64_t lba, uint32_t nsec, void *buf);	/* 0 ok */
int esp_flashblk_write(int vol, uint64_t lba, const void *buf, uint32_t nbytes);

#endif
