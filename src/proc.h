#ifndef PROC_H
#define PROC_H

/* the proc lifecycle: making one, confining it, arming its hooks,
 * pacing its collector, and taking it apart again. see docs/proc.md.
 */

#include <stddef.h>

#include "lua.h"
#include "kproc.h"

/* the proc table. A dead proc keeps its slot until the reaper runs at
 * the top of a lap, because dispatch reads its status right after a
 * resume that may have killed it.
 */
extern struct kproc *procv[MAXPROCS];	/* ipclock covers every walk */
extern int prochigh;		/* one past the highest slot ever used */
extern int nlive;		/* procs that are not DEAD */

/* the machine-wide lua heap, where NCPU is 1. Null above that, and that
 * is the test for whether a proc owns the heap it points at.
 */
extern struct luaheap *shared_heap;

/* the instruction budget a proc gets when it asks for none, measured at
 * boot so it stays a fixed fraction of the quantum.
 */
extern int default_reductions;

/* the proc holding a pid. find_proc wants ipclock held; the _locked
 * form takes it, which is what a sys.* call arriving with nothing held
 * needs.
 */
struct kproc *find_proc(int pid);
struct kproc *find_proc_locked(int pid);

/* make a proc, and let a made one run. They are separate because every
 * caller has setup to do in between -- the spawn argument, a driver's
 * device right, the boot proc's grants -- and a proc is born HATCHING
 * so no cpu can dispatch it half-built.
 */
int	proc_new(const char *code, size_t codelen, const char *chunkname,
	    int is_file, int reductions, size_t mem_limit, int port_limit,
	    int priv);
void	proc_launch(struct kproc *p);

/* end a proc: kill frees it, break holds it BROKE for inspection, reap
 * releases a corpse. All three detach it from the machine at once.
 */
void	proc_kill(struct kproc *p, const char *why);
void	proc_break(struct kproc *p, const char *why);
void	proc_reap(struct kproc *p);

/* deliver an exit notice to a watcher's self port. priv marks a
 * synthetic one, where the reason is the kernel's answer about the
 * request rather than anything the proc said. Caller holds ipclock.
 */
void	notify_exit(struct kproc *watcher, int pid, const char *reason,
	    int status, const char *exitmsg, int broke, int priv);

/* (re)size a proc's line-trace ring; 0 frees it. */
int	trace_arm(struct kproc *p, int n);

/* re-arm every coroutine of a proc after its hook mask changed. */
void	proc_armall(struct kproc *p, int count);
void	proc_rearm(struct kproc *p);

/* mark a discontinuity in a proc's trace -- a context switch, or a
 * collection -- so the histogram has somewhere honest to put the gap.
 */
void	trace_mark(struct kproc *p, const char *what);

/* one collector step for a proc, at a point where nothing is held. */
void	gc_step(struct kproc *p, lua_State *L, int mark);

/* collect a proc the scheduler is not running. The caller must hold the
 * proc the way dispatch does -- oncpu set, cpu_self()->current set --
 * because this runs that proc's finalizers.
 */
void	gc_idle_collect(struct kproc *p);

/* charge pooled buffer bytes against a proc's memory cap. */
int	kbuf_charge(lua_State *L, size_t n);
void	kbuf_uncharge(lua_State *L, size_t n);
int	kbuf_step_due(lua_State *L, size_t n);
size_t	kbuf_pooled(void);

/* release every proc's large-block cache on a quiet machine. */
size_t	proc_heaps_release(void);

/* a chunk allocation failed. Answered at the top of a lap, which is
 * the only place a proc may be killed.
 */
int	kmem_low(void);
void	kmem_low_clear(void);
int	kmem_short(void);

/* the proc to give up when memory runs short, or nil where nothing is
 * expendable. Only procs marked so at spawn are ever chosen.
 */
struct kproc *kmem_victim(void);

/* the C modules a proc may be given, registered in package.preload by
 * proc_new. Which ones depend on its privilege -- see docs/proc.md.
 */
extern int luaopen_los_efi(lua_State *L);		/* los.c: firmware info */
extern int luaopen_los_fs(lua_State *L);		/* dirs.c: readdir/stat */
extern int luaopen_los_inet(lua_State *L);		/* inet.c: checksum */
extern int luaopen_los_ninep(lua_State *L);	/* ninep.c: the 9P field codec */
extern int luaopen_los_crc(lua_State *L);		/* crc.c: crc16/crc32 */
extern int luaopen_los_font(lua_State *L);		/* font.c: glyphs */
extern int luaopen_los_buf(lua_State *L);		/* buf.c: byte buffers */
extern int luaopen_los_rom(lua_State *L);		/* vfs.c: the embed set */
extern int luaopen_ssh_crypto_native(lua_State *L);	/* native.c */
extern int luaopen_gefs_native(lua_State *L);	/* gefs_native.c */
extern int luaopen_dev(lua_State *L);		/* dev.c */
extern int luaopen_los_platform_cons(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_wire(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_power(lua_State *L);	/* drivers.c */
extern int luaopen_los_platform_p9(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_eth(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_blk(lua_State *L);	/* drivers.c: microvm only, no-op elsewhere */
extern int luaopen_los_platform_hci(lua_State *L);	/* drivers.c: esp32 only, absent elsewhere */
extern int luaopen_los_platform_flash(lua_State *L);	/* drivers.c: esp32 only, no-op elsewhere */
extern int luaopen_los_platform_wifi(lua_State *L);	/* drivers.c: esp32 only, no-op elsewhere */
extern int luaopen_los_platform_fb(lua_State *L);	/* gop.c: efi only, no-op elsewhere */
int	los_sys_open(lua_State *L);

/* registry keys: the string.format a proc was born with, and its
 * sys.atexit list. Addresses, not values.
 */
extern const char fmtkey;
extern const char atexit_key;

#endif
