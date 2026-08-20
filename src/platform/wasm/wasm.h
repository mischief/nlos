#ifndef WASM_WASM_H
#define WASM_WASM_H

/* what this platform's own files say to each other. Everything above
 * them is src/platform.h.
 */

#include <stddef.h>
#include <stdint.h>

/* linear memory, grown once at boot and handed to the allocator. */
void	mem_init(unsigned long long bytes);

void	pmm_add(uintptr_t base, size_t len);
void	*pmm_alloc(size_t n);
void	pmm_free(void *p, size_t n);
void	pmm_meminfo(size_t *total, size_t *avail, size_t *largest);

void	wasm_stall_us(unsigned long us);

/* the boot entry, exported to the embedder as "boot". */
void	wasm_boot(unsigned long long membytes);

#endif
