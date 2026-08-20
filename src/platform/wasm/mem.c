/* the machine's memory: one grow of linear memory, handed to pmm.c.
 * Once rather than on demand -- a wasm memory never shrinks, so growing
 * in pieces only leaves the guest's idea of its size moving.
 * __heap_base is where wasm-ld put the end of the static data.
 */

#include <stddef.h>
#include <stdint.h>

#include "platform.h"
#include "wasm.h"

#define PAGE 65536

extern char __heap_base[];

void
mem_init(unsigned long long bytes)
{
	uintptr_t base = (uintptr_t)__heap_base;
	unsigned long long want = (bytes + PAGE - 1) / PAGE;
	uintptr_t have = (uintptr_t)__builtin_wasm_memory_size(0) * PAGE;
	unsigned long long need;

	/* what the module already carries counts towards the ask: a
	 * default memory is not always one page. */
	need = base + (unsigned long long)want * PAGE > have
	    ? (base + (unsigned long long)want * PAGE - have + PAGE - 1) / PAGE
	    : 0;
	if (need && __builtin_wasm_memory_grow(0, (size_t)need) == (size_t)-1)
		platform_abort("mem: the host would not grow linear memory");

	have = (uintptr_t)__builtin_wasm_memory_size(0) * PAGE;
	if (have > base)
		pmm_add(base, have - base);
}
