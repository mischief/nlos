#ifndef DEBUG_H
#define DEBUG_H

#include <stdatomic.h>
#include <stddef.h>

#include "lua.h"

/* Push an array of { label, status, frames } onto `to`, describing every
 * coroutine of the proc whose main state is `target_main` and whose own
 * coroutine is `target_co`.
 *
 * Reads the target without running any of its code, allocating in its
 * heap, or leaving its stack changed. See debug.c for what that costs
 * and what it misses.
 */
void	debug_push_stacks(lua_State *to, lua_State *target_main,
	    lua_State *target_co);


#define DBGBP		16	/* breakpoints per proc */
#define DBGSRC		8	/* distinct source files interned */
#define DBGDEPTH	200	/* frames counted for a step-over */

/* why a proc stopped; an int because the hook stores it cross-cpu */
enum { DBG_RUN, DBG_REQ, DBG_BP, DBG_STEP, DBG_ENTRY };
enum { STEP_NONE, STEP_IN, STEP_OVER };

struct kbp {
	int fileid;		/* index into kdbg.file */
	int line;
	int enabled;
	unsigned int hits;
	int id;
};

/* What a proc under a debugger carries. C memory, not the target's,
 * for the reason struct ktrace gives. proc_hold is the lock and the
 * atomics escape it; field ownership is in docs/debugging.md.
 */
struct kdbg {
	/* the notice port as an (idx, gen) pair, never a pointer: see
	 * kproc.selfidx. A kernel ref holds the kport so the pair cannot
	 * come to name a stranger.
	 */
	unsigned short portidx;
	unsigned long long portgen;
	int dbgpid;		/* the debugger, for reporting only */

	char file[DBGSRC][LUA_IDSIZE];
	int nfile;
	/* ktrace's cache: compared, never dereferenced, because the
	 * string belongs to the target.
	 */
	const void *lastsrc;
	int lastid;

	struct kbp bp[DBGBP];
	int nbp;
	int nextid;
	/* OR of 1 << (line & 63) over enabled breakpoints: a line that
	 * matches nothing costs a shift and a test.
	 */
	unsigned long long linemask;

	atomic_int pending;	/* DBG_*: the hook has decided to stop */
	atomic_int stopreq;	/* the debugger wants the next event */
	atomic_int notify;	/* DBG_*: a stop dbg_sweep still has to send */
	atomic_int detach;	/* the debugger died; dbg_settle tears it down */

	int step;
	lua_State *stepco;
	int stepdepth;

	/* where it stopped; stopco is touched only while the proc is held */
	lua_State *stopco;
	int stopline;
	int stopfile;		/* index into file[], or -1 */
	int stopbp;		/* breakpoint id, or 0 */
	int reason;		/* DBG_* */
};

/* Set a fresh kdbg to its resting state: no breakpoints, no step, no
 * stop, and the interning caches empty.
 */
void	dbg_init(struct kdbg *d, int dbgpid);

/* Intern a source name; -1 when the table is full. Written by the
 * target's hook or by a holder, which proc_hold keeps apart.
 */
int	dbg_intern(struct kdbg *d, const void *srcptr, const char *name);

/* Rebuild the line mask. Always before the hook mask is recomputed. */
void	dbg_remask(struct kdbg *d);

/* Does this proc want line events? The one question the hook mask asks
 * of the debugger.
 */
int	dbg_wants_lines(struct kdbg *d);

/* Record a stop the hook has decided on. Advisory: it is committed at
 * the kernel boundary, because the yield after it can be swallowed.
 */
void	dbg_arm_stop(struct kdbg *d, lua_State *L, lua_Debug *ar,
	    int reason, int bp);

/* A line event on a proc under a debugger: the hot path. Returns
 * whether a stop was armed.
 */
int	dbg_line(struct kdbg *d, lua_State *L, lua_Debug *ar);

/* How many frames are open on a state, bounded by DBGDEPTH. */
int	dbg_depth(lua_State *L);

/* "request", "breakpoint", "step", ... for a DBG_* reason. */
const char *dbg_reasonstr(int reason);

/* Readers for los.dbg, on a proc held still by proc_hold. All of them
 * keep src/debug.c's three rules, and none of them writes.
 */

/* one hop of a value path. A literal key, never an expression. */
enum { DBGKEY_STR, DBGKEY_INT };

struct dbgkey {
	int kind;
	const char *s;
	size_t slen;
	lua_Integer i;
};

/* where a value is rooted */
enum { DBGROOT_LOCAL, DBGROOT_UPVAL, DBGROOT_GLOBAL };

#define DBGPATH		8	/* hops per path */
#define DBGKEYS		32	/* table keys reported for navigation */
#define DBGSTRMAX	256	/* bytes of a string copied out */

/* Push { {source=, line=, name=, what=, nlocals=, nups=}, ... } for the
 * frames open on `co`, outermost last.
 */
void	dbg_push_frames(lua_State *to, lua_State *co);

/* Push { {name=, internal=, value=}, ... } for a frame's locals or
 * upvalues; level 0 is innermost. These PUSH onto the target, so the
 * caller records its top before any pcall and restores it after.
 */
void	dbg_push_locals(lua_State *to, lua_State *co, int level);
void	dbg_push_upvals(lua_State *to, lua_State *co, int level);

/* Push a descriptor of one value, named and then walked by literal
 * keys. Returns 0 and pushes nothing if the root or a hop is missing.
 */
int	dbg_push_path(lua_State *to, lua_State *co, int level, int root,
	    const char *name, size_t nlen, const struct dbgkey *path,
	    int npath);

#endif
