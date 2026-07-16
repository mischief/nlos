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

#endif
