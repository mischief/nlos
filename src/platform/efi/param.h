/* per-platform kernel table sizes. see kernel.c for what they cost and
 * why they are headroom rather than reachable counts.
 *
 * a pc booted from firmware has ram to spare and no idea what it will
 * be asked to run, so this is the generous end: the tables cost 288KB
 * of .bss on a 64-bit target, against a heap that runs out at about
 * 960 procs anyway.
 */
#define MAXPROCS	4096
#define MAXPORTS	32768
