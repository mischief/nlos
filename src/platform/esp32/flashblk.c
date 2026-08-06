/* the luafs partition, as a block device.
 *
 * Deliberately not esp_vfs_fat_spiflash_mount, for the reason blk.c
 * gives for refusing the microSD equivalent: that mounts a filesystem
 * in C behind IDF's VFS and hands back a POSIX path, which is the
 * ambient authority kernel_strip_io exists to take away. What lua-os
 * wants is the layer below -- sectors -- so that one filesystem in Lua
 * serves the card and the flash alike, and is testable on a host
 * against a plain file.
 *
 * No wear levelling under this. The partition holds bin/ and lib/: it
 * is read every boot and written when someone uploads a program, and at
 * that rate the erase count of the busiest sector stays far inside what
 * NOR flash is rated for. A partition taking constant writes would need
 * more than this file provides.
 */

#include <stdint.h>
#include <string.h>

#include <esp_partition.h>

#include "flashblk.h"
#include "platform.h"

/* the name in esp32/partitions.csv. Found by name rather than by
 * subtype: the subtype says what the bytes are meant to be, and more
 * than one partition may claim it.
 */
#define LUAFS_LABEL "luafs"

static const esp_partition_t *part;
static int probed;

int
esp_flashblk_present(void)
{
	if (!probed) {
		probed = 1;
		part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
		    ESP_PARTITION_SUBTYPE_DATA_FAT, LUAFS_LABEL);
	}
	return part != NULL;
}

uint32_t
esp_flashblk_secsz(void)
{
	if (!esp_flashblk_present())
		return 0;
	/* the erase block, which is what makes a write one erase. */
	return part->erase_size;
}

uint64_t
esp_flashblk_sectors(void)
{
	uint32_t secsz = esp_flashblk_secsz();

	if (secsz == 0)
		return 0;
	return part->size / secsz;
}

/* the caller's buffer is written into directly. esp_partition_read maps
 * the flash rather than staging it, so there is no equivalent of the
 * DMA buffer blk.c needs.
 */
int
esp_flashblk_read(uint64_t lba, uint32_t nsec, void *buf)
{
	uint32_t secsz = esp_flashblk_secsz();

	if (secsz == 0 || lba + nsec > esp_flashblk_sectors())
		return -1;
	if (esp_partition_read(part, (size_t)(lba * secsz), buf,
	    (size_t)nsec * secsz) != ESP_OK)
		return -1;
	return 0;
}

/* Erase then program, one whole sector at a time.
 *
 * Neither half is atomic and there is no journal above this, so a power
 * loss between them leaves that sector erased. That is the failure
 * FAT's checker is for: lib/fat's check() names a chain that no longer
 * reads, and the file being written is the one that is lost.
 */
int
esp_flashblk_write(uint64_t lba, const void *buf, uint32_t nbytes)
{
	uint32_t secsz = esp_flashblk_secsz();
	size_t off;

	if (secsz == 0 || nbytes == 0 || nbytes % secsz != 0)
		return -1;
	if (lba + nbytes / secsz > esp_flashblk_sectors())
		return -1;

	off = (size_t)(lba * secsz);
	if (esp_partition_erase_range(part, off, nbytes) != ESP_OK)
		return -1;
	if (esp_partition_write(part, off, buf, nbytes) != ESP_OK)
		return -1;
	return 0;
}
