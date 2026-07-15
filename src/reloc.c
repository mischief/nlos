/* self-relocation: apply R_X86_64_RELATIVE relocations left in the
 * image by ld -shared, using the actual load address as the base.
 * runs before anything touches globals holding absolute addresses.
 */

#include <stdint.h>

#define R_X86_64_RELATIVE 8

typedef struct {
	uint64_t r_offset;
	uint64_t r_info;
	int64_t  r_addend;
} Elf64_Rela;

extern char __rela_start[], __rela_end[];

void
self_relocate(char *base)
{
	Elf64_Rela *r;

	for (r = (Elf64_Rela *)__rela_start; r < (Elf64_Rela *)__rela_end; r++) {
		if ((r->r_info & 0xffffffff) == R_X86_64_RELATIVE)
			*(uint64_t *)(base + r->r_offset) =
			    (uint64_t)(base + r->r_addend);
	}
}
