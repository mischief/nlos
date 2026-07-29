#ifndef KERNEL_H
#define KERNEL_H

/* mach-lite: procs are isolated lua_States, ports are kernel message
 * queues, rights are per-proc handles onto ports.
 */

int	kernel_init(void);
int	kernel_spawn_file(const char *path);	/* returns pid or -1 */
int	kernel_spawn_buffer(const char *code, unsigned long len);
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
void	*kernel_new_net_event(void);

#endif
