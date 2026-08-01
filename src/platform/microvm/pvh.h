#ifndef PVH_H
#define PVH_H

/* the PVH boot ABI, as an external interface we do not get to choose:
 * these layouts are Xen's (docs/misc/pvh.pandoc, xen/include/public/
 * arch-x86/hvm/start_info.h) and qemu's microvm machine fills them in.
 * boot.S stashes the struct's physical address from ebx.
 *
 * Everything is identity-mapped when we read this, so a physical
 * address is a pointer.
 */

#include <stdint.h>

#define PVH_START_MAGIC 0x336ec578	/* "xEn3" */

struct hvm_start_info {
	uint32_t magic;
	uint32_t version;
	uint32_t flags;
	uint32_t nr_modules;
	uint64_t modlist_paddr;
	uint64_t cmdline_paddr;
	uint64_t rsdp_paddr;
	/* version 1 and above only -- check version before reading */
	uint64_t memmap_paddr;
	uint32_t memmap_entries;
	uint32_t reserved;
};

struct hvm_memmap_table_entry {
	uint64_t addr;
	uint64_t size;
	uint32_t type;
	uint32_t reserved;
};

/* the only type we may allocate from; the rest (reserved, acpi, nvs,
 * unusable, disabled, pmem) are either not ours or not memory.
 */
#define PVH_MEMMAP_TYPE_RAM 1

#endif
