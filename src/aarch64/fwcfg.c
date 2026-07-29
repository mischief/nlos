/* qemu fw_cfg, mmio flavor: the virt machine puts the register block at
 * a fixed address (data at +0, selector at +8, big-endian 16-bit).
 * used by the test harness to inject a boot payload without touching
 * the disk image. absent hardware (or real hardware) fails the
 * signature check and we carry on -- the region is device memory the
 * firmware has already mapped, so a read there is harmless either way.
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "platform.h"

#define FWCFG_BASE	0x09020000UL

#define REG_DATA	0x00
#define REG_SEL		0x08

#define FW_CFG_SIGNATURE	0x0000
#define FW_CFG_FILE_DIR		0x0019

static void
fwcfg_select(uint16_t key)
{
	*(volatile uint16_t *)(FWCFG_BASE + REG_SEL) = __builtin_bswap16(key);
}

/* byte-at-a-time: the data register accepts 1/2/4/8-byte reads and
 * only the wide ones have an endianness to get wrong.
 */
static void
fwcfg_readn(void *buf, size_t n)
{
	volatile uint8_t *data = (volatile uint8_t *)(FWCFG_BASE + REG_DATA);
	unsigned char *p = buf;

	while (n--)
		*p++ = *data;
}

static uint32_t
be32(uint32_t v)
{
	return __builtin_bswap32(v);
}

static uint16_t
be16(uint16_t v)
{
	return __builtin_bswap16(v);
}

/* find a named file; on success allocate and read its contents.
 * returns 0 and sets buf/len, or -1.
 */
int
fwcfg_load(const char *name, char **buf, size_t *len)
{
	char sig[4];
	uint32_t count;

	fwcfg_select(FW_CFG_SIGNATURE);
	fwcfg_readn(sig, 4);
	if (memcmp(sig, "QEMU", 4) != 0)
		return -1;

	fwcfg_select(FW_CFG_FILE_DIR);
	fwcfg_readn(&count, 4);
	count = be32(count);
	if (count > 1024)
		return -1;

	struct {
		uint32_t size;
		uint16_t select;
		uint16_t reserved;
		char name[56];
	} ent;

	for (uint32_t i = 0; i < count; i++) {
		fwcfg_readn(&ent, sizeof ent);
		if (strncmp(ent.name, name, sizeof ent.name) != 0)
			continue;

		uint32_t size = be32(ent.size);
		uint16_t select = be16(ent.select);
		char *p = malloc(size);

		if (!p)
			return -1;
		fwcfg_select(select);
		fwcfg_readn(p, size);
		*buf = p;
		*len = size;
		return 0;
	}
	return -1;
}
