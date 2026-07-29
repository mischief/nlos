/* qemu fw_cfg, mmio flavor: the virt machines put the register block at
 * a fixed address (data at +0, selector at +8, big-endian 16-bit).
 * used by the test harness to inject a boot payload without touching
 * the disk image. absent hardware (or real hardware) fails the
 * signature check and we carry on -- the region is device memory the
 * firmware has already mapped, so a read there is harmless either way.
 *
 * only the base address differs between the arm and riscv virt
 * machines, so it comes from meson.build rather than forking the file;
 * the register layout above is qemu's, not any one machine's.
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "platform.h"

#ifndef FWCFG_BASE
#error "meson.build must define FWCFG_BASE for this machine"
#endif

#define REG_DATA	0x00
#define REG_SEL		0x08

#define FW_CFG_SIGNATURE	0x0000
#define FW_CFG_FILE_DIR		0x0019

/* by hand rather than __builtin_bswap*: riscv64 without Zbb has no
 * byte-reverse instruction, so gcc lowers the builtin to a call to
 * __bswapsi2 -- and that symbol exists only in libgcc, which we do not
 * link. shifts still compile to the one `rev` on aarch64.
 *
 * note what the rule actually is, because half this file's neighbours
 * appear to break it: a builtin lowering to a *call* is fine, so long
 * as we own the symbol it calls. __builtin_floor and __builtin_fmod
 * also become calls on riscv64 -- to floor() and fmod(), which are
 * ours (src/riscv64/math.c, src/libc/softmath.c). __bswapsi2 is the
 * one that is nobody's but libgcc's, so it is the one to avoid.
 */
static uint16_t
be16(uint16_t v)
{
	return (uint16_t)((v >> 8) | (v << 8));
}

static uint32_t
be32(uint32_t v)
{
	return (v >> 24) | ((v >> 8) & 0xff00) |
	    ((v << 8) & 0xff0000) | (v << 24);
}

static void
fwcfg_select(uint16_t key)
{
	*(volatile uint16_t *)(FWCFG_BASE + REG_SEL) = be16(key);
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
