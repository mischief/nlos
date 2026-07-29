/* self-relocation: apply R_RISCV_RELATIVE relocations left in the
 * image by ld -shared, using the actual load address as the base.
 * runs before anything touches globals holding absolute addresses.
 */

#include <stdint.h>
#include "platform.h"

#define R_RISCV_RELATIVE 3

typedef struct {
	uint64_t r_offset;
	uint64_t r_info;
	int64_t  r_addend;
} Elf64_Rela;

/* explicitly hidden, for the reason spelled out in src/aarch64/reloc.c:
 * -fvisibility=hidden governs definitions, not extern declarations, so
 * without this gcc reaches these two through the GOT -- and the GOT is
 * precisely what has not been relocated yet when this runs. hidden lets
 * it use an auipc/addi pair instead, which needs no relocation at all.
 */
extern char __rela_start[] __attribute__((visibility("hidden")));
extern char __rela_end[] __attribute__((visibility("hidden")));

void
self_relocate(char *base)
{
	Elf64_Rela *r;

	for (r = (Elf64_Rela *)__rela_start; r < (Elf64_Rela *)__rela_end; r++) {
		if ((r->r_info & 0xffffffff) == R_RISCV_RELATIVE)
			*(uint64_t *)(base + r->r_offset) =
			    (uint64_t)(base + r->r_addend);
	}
}
