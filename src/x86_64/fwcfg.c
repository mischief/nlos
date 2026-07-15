/* qemu fw_cfg, port io flavor: selector 0x510, data 0x511.
 * used by the test harness to inject a boot payload without touching
 * the disk image. absent hardware (or real hardware) fails the
 * signature check and we carry on.
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "platform.h"

#define SEL_PORT	0x510
#define DATA_PORT	0x511

#define FW_CFG_SIGNATURE	0x0000
#define FW_CFG_FILE_DIR		0x0019

static inline void
outw(unsigned short port, unsigned short v)
{
	__asm__ volatile ("outw %0, %1" : : "a" (v), "Nd" (port));
}

static inline unsigned char
inb(unsigned short port)
{
	unsigned char v;

	__asm__ volatile ("inb %1, %0" : "=a" (v) : "Nd" (port));
	return v;
}

static void
fwcfg_readn(void *buf, size_t n)
{
	unsigned char *p = buf;

	while (n--)
		*p++ = inb(DATA_PORT);
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

	outw(SEL_PORT, FW_CFG_SIGNATURE);
	fwcfg_readn(sig, 4);
	if (memcmp(sig, "QEMU", 4) != 0)
		return -1;

	outw(SEL_PORT, FW_CFG_FILE_DIR);
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
		outw(SEL_PORT, select);
		fwcfg_readn(p, size);
		*buf = p;
		*len = size;
		return 0;
	}
	return -1;
}
