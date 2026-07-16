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

/* dynamic wait-set for token/Event-based device completions (net.c's
 * tcp4 tokens today). register while an operation is outstanding,
 * unregister once its Event has fired and been handled.
 */
int	kernel_register_wait_event(void *event);
void	kernel_unregister_wait_event(void *event);

/* net.c calls this instead of BS->CreateEvent directly for every
 * completion token it creates: wires the kernel's own notify
 * (wakes whoever holds netport's recv right via an ordinary
 * port_push, same mechanism as every other blocking primitive here)
 * and registers the event in the dynamic wait-set above. returns 0
 * (NULL) on failure, same convention as CreateEvent's out-param.
 */
void	*kernel_new_net_event(void);

#endif
