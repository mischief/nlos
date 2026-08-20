#ifndef WASM_HOST_H
#define WASM_HOST_H

/* everything this machine cannot do for itself, as wasm imports from
 * the module "luaos". The whole platform seam is these six calls, so a
 * new embedder -- a page, a shell, a test harness -- writes six
 * functions and has a machine.
 */

#include <stddef.h>

#define HOSTFN(name) \
	__attribute__((import_module("luaos"), import_name(#name)))

/* bytes to the console. */
HOSTFN(write) void host_write(const void *p, size_t n);

/* the next console byte, or -1 when none is waiting. Never blocks. */
HOSTFN(read) int host_read(void);

/* a monotonic nanosecond count. Its epoch is the host's business. */
HOSTFN(now_ns) unsigned long long host_now_ns(void);

/* sleep until a byte arrives or the milliseconds run out, whichever is
 * first. A host that cannot block may return at once: the caller is a
 * scheduler that will ask again.
 */
HOSTFN(wait) void host_wait(int ms);

/* fill with entropy. A host with none must say so rather than pretend:
 * answer 0, and the machine does without. */
HOSTFN(random) int host_random(void *p, size_t n);

/* every proc has exited, or something asked to power off. */
HOSTFN(exit) _Noreturn void host_exit(int code);

#undef HOSTFN

#endif
