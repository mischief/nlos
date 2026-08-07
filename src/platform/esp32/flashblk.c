/* the data partitions, as block devices.
 *
 * Deliberately not esp_vfs_fat_spiflash_mount, for the reason blk.c
 * gives for refusing the microSD equivalent: that mounts a filesystem
 * in C behind IDF's VFS and hands back a POSIX path, which is the
 * ambient authority kernel_strip_io exists to take away. What lua-os
 * wants is the layer below -- sectors -- so that one filesystem in Lua
 * serves the card and the flash alike, and is testable on a host
 * against a plain file.
 *
 * No wear levelling under this. The partitions hold bin/ and lib/ and
 * what the machine knows about itself: they are read every boot and
 * written when someone uploads a program or sets a network, and at that
 * rate the erase count of the busiest sector stays far inside what NOR
 * flash is rated for. A partition taking constant writes would need
 * more than this file provides.
 */

#include <stdint.h>
#include <string.h>

#include <esp_partition.h>

#include "flashblk.h"
#include "platform.h"

/* the names in esp32/partitions.csv, in volume order. Found by name
 * rather than by subtype: the subtype says what the bytes are meant to
 * be, and more than one partition claims it -- both of these do.
 *
 * Volume 0 is luafs and must stay first: it is what a board with no
 * config partition still has, and what the single-volume calls reach.
 */
static const char *const labels[ESP_FLASHBLK_NVOL] = { "luafs", "config" };

static const esp_partition_t *part[ESP_FLASHBLK_NVOL];
static int probed[ESP_FLASHBLK_NVOL];

int
esp_flashblk_present(int vol)
{
	if (vol < 0 || vol >= ESP_FLASHBLK_NVOL)
		return 0;
	if (!probed[vol]) {
		probed[vol] = 1;
		part[vol] = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
		    ESP_PARTITION_SUBTYPE_DATA_FAT, labels[vol]);
	}
	return part[vol] != NULL;
}

uint32_t
esp_flashblk_secsz(int vol)
{
	if (!esp_flashblk_present(vol))
		return 0;
	/* the erase block, which is what makes a write one erase. */
	return part[vol]->erase_size;
}

uint64_t
esp_flashblk_sectors(int vol)
{
	uint32_t secsz = esp_flashblk_secsz(vol);

	if (secsz == 0)
		return 0;
	return part[vol]->size / secsz;
}

/* the caller's buffer is written into directly. esp_partition_read maps
 * the flash rather than staging it, so there is no equivalent of the
 * DMA buffer blk.c needs.
 */
int
esp_flashblk_read(int vol, uint64_t lba, uint32_t nsec, void *buf)
{
	uint32_t secsz = esp_flashblk_secsz(vol);

	if (secsz == 0 || lba + nsec > esp_flashblk_sectors(vol))
		return -1;
	if (esp_partition_read(part[vol], (size_t)(lba * secsz), buf,
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
esp_flashblk_write(int vol, uint64_t lba, const void *buf, uint32_t nbytes)
{
	uint32_t secsz = esp_flashblk_secsz(vol);
	size_t off;

	if (secsz == 0 || nbytes == 0 || nbytes % secsz != 0)
		return -1;
	if (lba + nbytes / secsz > esp_flashblk_sectors(vol))
		return -1;

	off = (size_t)(lba * secsz);
	if (esp_partition_erase_range(part[vol], off, nbytes) != ESP_OK)
		return -1;
	if (esp_partition_write(part[vol], off, buf, nbytes) != ESP_OK)
		return -1;
	return 0;
}
