/* EFI_BLOCK_IO_PROTOCOL, wrapped to the same surface microvm's virtio_blk
 * gives: raw sectors off the disk with no notion of what they mean. The
 * firmware does not exit boot services here (that is why SNP runs at
 * kernel time, and why this can too), so ReadBlocks/WriteBlocks stay
 * callable the whole way through.
 *
 * The whole disk, not a partition: LogicalPartition == 0. That is the
 * device blkfs.lua serves as /data, over which lib/gpt.lua reads the
 * table and gefs.slice cuts out the gefs partition -- the identical stack
 * microvm_gefsgpt.lua drives, none of which knows a partition from a
 * platform. Unlike SNP there is no unbinding to do: reading a disk does
 * not compete with the firmware the way taking its NIC does, and the ESP
 * the firmware still holds is a different partition handle from this one.
 */

#include "efi.h"
#include "blk.h"

static EFI_BLOCK_IO_PROTOCOL *disk;

static EFI_GUID blkio_guid = { 0x964e5b21, 0x6459, 0x11d2,
    { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } };

int
efi_blk_present(void)
{
	EFI_HANDLE *handles = 0;
	UINTN count = 0, i;

	if (disk)
		return 1;

	if (BS->LocateHandleBuffer(2 /* ByProtocol */, &blkio_guid, 0,
	    &count, &handles) != EFI_SUCCESS || count == 0)
		return 0;

	for (i = 0; i < count; i++) {
		EFI_BLOCK_IO_PROTOCOL *p = 0;

		if (BS->HandleProtocol(handles[i], &blkio_guid,
		    (void **)&p) != EFI_SUCCESS || !p || !p->Media)
			continue;
		/* a present whole disk, not a partition the firmware split
		 * off it. The first is the only disk in the qemu setup; a
		 * machine with several would want the boot disk, which the
		 * loaded-image device path names -- a refinement for later.
		 */
		if (p->Media->MediaPresent && !p->Media->LogicalPartition) {
			disk = p;
			break;
		}
	}
	if (handles)
		BS->FreePool(handles);
	return disk != 0;
}

uint64_t
efi_blk_sectors(void)
{
	return disk ? disk->Media->LastBlock + 1 : 0;
}

uint32_t
efi_blk_secsz(void)
{
	return disk ? disk->Media->BlockSize : 0;
}

int
efi_blk_read(uint64_t lba, uint32_t nsec, void *buf)
{
	if (!disk)
		return -1;
	return disk->ReadBlocks(disk, disk->Media->MediaId, (EFI_LBA)lba,
	    (UINTN)nsec * disk->Media->BlockSize, buf) == EFI_SUCCESS ? 0 : -1;
}

int
efi_blk_write(uint64_t lba, const void *buf, uint32_t nbytes)
{
	if (!disk || disk->Media->ReadOnly)
		return -1;
	return disk->WriteBlocks(disk, disk->Media->MediaId, (EFI_LBA)lba,
	    (UINTN)nbytes, (void *)buf) == EFI_SUCCESS ? 0 : -1;
}
