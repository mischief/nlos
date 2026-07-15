#ifndef KERNEL_H
#define KERNEL_H

/* mach-lite: procs are isolated lua_States, ports are kernel message
 * queues, rights are per-proc handles onto ports.
 */

int	kernel_init(void);
int	kernel_spawn_file(const char *path);	/* returns pid or -1 */
void	kernel_run(void);			/* until all procs die */

#endif
