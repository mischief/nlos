/* self-relocation: apply R_AARCH64_RELATIVE relocations left in the
 * image by ld -shared, using the actual load address as the base.
 * runs before anything touches globals holding absolute addresses.
 */

#include <stdint.h>
#include "platform.h"

#define R_AARCH64_RELATIVE 1027

typedef struct {
	uint64_t r_offset;
	uint64_t r_info;
	int64_t  r_addend;
} Elf64_Rela;

/* explicitly hidden, and that is load-bearing rather than tidiness.
 * -fvisibility=hidden governs definitions, not extern declarations, so
 * without this gcc reaches these two through the GOT -- and the GOT is
 * precisely what has not been relocated yet when this runs. it read
 * link-time addresses, walked whatever firmware memory happened to sit
 * at them, and wrote the results over our own GOT. hidden lets it use
 * an adrp/add pair instead, which needs no relocation at all.
 * x86_64 never had the problem: it addresses these rip-relative.
 */
extern char __rela_start[] __attribute__((visibility("hidden")));
extern char __rela_end[] __attribute__((visibility("hidden")));

void
self_relocate(char *base)
{
	Elf64_Rela *r;

	for (r = (Elf64_Rela *)__rela_start; r < (Elf64_Rela *)__rela_end; r++) {
		if ((r->r_info & 0xffffffff) == R_AARCH64_RELATIVE)
			*(uint64_t *)(base + r->r_offset) =
			    (uint64_t)(base + r->r_addend);
	}
}
