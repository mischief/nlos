#ifndef SYSAPI_H
#define SYSAPI_H

/* the los.sys syscalls, and the two things a cross-proc one needs: a
 * way to hold the target still, and a way to ask whether it may.
 */

#include "lua.h"
#include "kproc.h"

/* the proc a lua_State belongs to. */
struct kproc *self(lua_State *L);

/* may this proc act on that one? Holding a right to the target's self
 * port is the authority. It gates what acts on a proc, not what reads
 * one -- see docs/debugging.md on which side each call sits.
 */
int	may_control(struct kproc *p, struct kproc *target);

/* is this proc the only holder of a right to `port`? That is our eof. */
int	sole_holder(struct kproc *p, struct kport *port);

/* the shape every cross-proc syscall takes. proc_hold reports which
 * situation the caller is in and lets it yield by name, because
 * lua_yieldk names a continuation and each syscall's is its own.
 */
enum { HOLD_SELF, HOLD_HELD, HOLD_WAIT, HOLD_GONE };

int	proc_hold(lua_State *L, int argn, struct kproc **out, lua_KContext ctx);

/* a park must be issued from the state the kernel resumed; raises if
 * not. See docs/scheduling.md on where a yield lands.
 */
void	nopark(lua_State *L, struct kproc *p);

/* serialize the value at `idx` and queue it on r's port, disposing of
 * the buffer on every path. `len`, if given, is filled with the
 * serialized size -- which is what a caller needs to wait for room.
 */
enum { SEND_OK = 0, SEND_UNSERIALIZABLE, SEND_DEAD, SEND_FULL, SEND_NOMEM };

int	port_send_from_lua(lua_State *L, struct kproc *p, struct right *r,
	    int idx, size_t *len);

/* push a popped message as one lua value and dispose of it, or name
 * which local limit stopped it.
 */
int	msg_to_lua(lua_State *L, struct kproc *p, struct kmsg *m);
int	popfail(lua_State *L, struct kproc *p, int rc);

/* the wchan string for a proc, so every reporter agrees. */
int	push_wchan(lua_State *L, struct kproc *p);

/* the los.dbg opener, and what the dispatch loop owes the debugger:
 * settle a proc this cpu owns, commit a stop it asked for, and sweep
 * the notices. See docs/debugging.md.
 */
int	dbg_commit(struct kproc *p);
void	dbg_settle(struct kproc *p);
void	dbg_sweep(void);
void	dbg_mark_orphan(struct kproc *p);

#endif
