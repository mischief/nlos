#ifndef KERNEL_H
#define KERNEL_H

/* mach-lite: procs are isolated lua_States, ports are kernel message
 * queues, rights are per-proc handles onto ports.
 */

#include <stddef.h>

/* the TSC epoch and rate. must run before anything measures a duration
 * or logs a line; efi_main calls it first. costs 100ms of BS->Stall.
 */
void	kernel_clock_init(void);
unsigned long long kernel_cyc_per_ms(void);

/* one stamped, newline-terminated diagnostic line. shares its format
 * with lib/log.lua -- change one and change the other.
 */
void	kernel_log(const char *s);

int	kernel_init(void);
int	kernel_spawn_file(const char *path);	/* returns pid or -1 */
int	kernel_spawn_buffer(const char *code, size_t len);
void	kernel_run(void);			/* until all procs die */

/* checked capability, write/append only (read is ambient): does
 * whoever's currently resumed hold a right to the disk port? used
 * from stdio.c's fopen, which has no lua_State to check a right
 * against directly (liolib.c calls it as plain C).
 */
int	kernel_current_has_disk(void);

/* the file half of io is removed from every proc but proc 0 (see
 * proc_new). it has to be removable from TWO places, because linit.c
 * loads io lazily through a metatable on _G and luaL_requiref re-runs
 * the opener whenever package.loaded[name] is falsy -- which an
 * unprivileged proc can arrange, handing itself a fresh working
 * io.open. so the lazy loader re-strips, using these.
 *
 * kernel_strip_io expects the io table on top of the stack and leaves
 * it there.
 */
struct lua_State;
void	kernel_strip_io(struct lua_State *L);

/* kernel_strip_debug expects the debug table on top of the stack and
 * leaves it there. Same contract, same reason, same re-strip hazard.
 */
void	kernel_strip_debug(struct lua_State *L);
/* kernel_wrap_coroutine expects the coroutine table on top of the stack
 * and replaces wrap with one that is transparent to preemption.
 */
void	kernel_wrap_coroutine(struct lua_State *L);
int	kernel_current_is_boot(void);

/* dynamic wait-set for token/Event-based device completions (net.c's
 * tcp4 tokens today). register while an operation is outstanding,
 * unregister once its Event has fired and been handled.
 */

/* net.c calls this instead of BS->CreateEvent directly for every
 * completion token it creates: wires the kernel's own notify
 * (wakes whoever holds netport's recv right via an ordinary
 * port_push, same mechanism as every other blocking primitive here)
 * and registers the event in the dynamic wait-set above. returns 0
 * (NULL) on failure, same convention as CreateEvent's out-param.
 */

#endif
