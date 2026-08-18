/* los.dbg: stopping a proc, reading it, and letting it go again. Every
 * function here names a target and gates on a right to it. See
 * docs/debugging.md.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <sys/queue.h>

#include "lua.h"
#include "lauxlib.h"
#include "lock.h"
#include "cpu.h"
#include "debug.h"
#include "kernel.h"
#include "kproc.h"
#include "port.h"
#include "proc.h"
#include "ksched.h"
#include "serialize.h"
#include "sysapi.h"
#include "platform.h"

/* The readers, all one shape: hold the target, run a body from
 * src/dbg.c under pcall, restore the target's top, thaw.
 */
struct dbgread {
	struct kproc *p;
	int co, level, root, npath;
	const char *name;
	size_t nlen;
	struct dbgkey path[DBGPATH];
};

static int dbg_read_body(lua_State *L);
static const char *dbg_acting(lua_State *L, struct kproc *p);
static int api_dbg_attach_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_breaks_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_clearbreak_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_cont_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_coros_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_detach_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_frames_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_get_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_locals_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_setbreak_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_status_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_step_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_stop_k(lua_State *L, int status, lua_KContext ctx);
static int api_dbg_upvalues_k(lua_State *L, int status, lua_KContext ctx);
static struct kport *dbg_port(struct kdbg *d);
static int dbg_orphaned(struct kdbg *d);
static int dbg_coidx(struct kproc *p, lua_State *co);
static lua_State *dbg_costate(struct kproc *p, int co);
static void dbg_push_status(lua_State *L, struct kproc *p);

static int
may_debug(struct kproc *p, struct kproc *target)
{
	return may_control(p, target) || proc_has_port(p, dbgport);
}

/* the target of an acting call, held and checked. Every caller thaws
 * before it raises: a raise past the thaw leaves the target frozen for
 * good, which is a worse bug than whatever was being refused.
 */
static const char *
dbg_acting(lua_State *L, struct kproc *p)
{
	if (!may_debug(self(L), p))
		return "no right to debug that proc";
	if (!p->dbg)
		return "not attached";
	return 0;
}

static int
dbg_breaks_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct kdbg *d = p->dbg;

	lua_createtable(L, d ? d->nbp : 0, 0);
	for (int i = 0; d && i < d->nbp; i++) {
		lua_createtable(L, 0, 5);
		lua_pushinteger(L, d->bp[i].id);
		lua_setfield(L, -2, "id");
		lua_pushstring(L, d->file[d->bp[i].fileid]);
		lua_setfield(L, -2, "file");
		lua_pushinteger(L, d->bp[i].line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, d->bp[i].hits);
		lua_setfield(L, -2, "hits");
		lua_pushboolean(L, d->bp[i].enabled);
		lua_setfield(L, -2, "enabled");
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* Where in p->coros a state sits, 1-based: the coroutine ABI los.dbg
 * takes and reports. Not sys.stack's ordering -- p->L is not on this
 * list. Read only while the proc is held.
 */
static int
dbg_coidx(struct kproc *p, lua_State *co)
{
	struct kextra *kx;
	int i = 1;

	if (!co)
		return 0;
	TAILQ_FOREACH(kx, &p->coros, link) {
		if (kx_state(kx) == co)
			return i;
		i++;
	}
	return 0;
}

/* the kernel boundary: p->co has just yielded, and this cpu owns p.
 * Returns whether the proc is now stopped and must not be resumed.
 */
int
dbg_commit(struct kproc *p)
{
	struct kdbg *d = p->dbg;

	if (!d)
		return 0;

	int reason = atomic_exchange_explicit(&d->pending, DBG_RUN,
	    memory_order_relaxed);

	if (reason == DBG_RUN)
		return 0;

	lock(&schedlock);
	p->status = STOPPED;
	unlock(&schedlock);
	/* dbg_sweep sends it: a notice needs the ipc lock and this is not
	 * the place to take it.
	 */
	atomic_store_explicit(&d->notify, reason, memory_order_relaxed);
	return 1;
}

static int
dbg_coros_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct kdbg *d = p->dbg;
	struct kextra *kx;
	int i = 0;

	lua_newtable(L);
	TAILQ_FOREACH(kx, &p->coros, link) {
		lua_State *co = kx_state(kx);

		lua_createtable(L, 0, 4);
		lua_pushinteger(L, ++i);
		lua_setfield(L, -2, "i");
		lua_pushstring(L, co == p->co ? "main" : "coroutine");
		lua_setfield(L, -2, "label");
		lua_pushinteger(L, lua_status(co));
		lua_setfield(L, -2, "status");
		if (d && d->stopco == co) {
			lua_pushboolean(L, 1);
			lua_setfield(L, -2, "stopped");
		}
		lua_rawseti(L, -2, i);
	}
	return 1;
}

static lua_State *
dbg_costate(struct kproc *p, int co)
{
	struct kextra *kx;
	int i = 1;

	TAILQ_FOREACH(kx, &p->coros, link) {
		if (i++ == co)
			return kx_state(kx);
	}
	return 0;
}

/* All of it under the wide lock, which is what dbg_sweep reads p->dbg
 * inside: clearing and freeing anywhere else is a use-after-free on the
 * cpu walking the table. Callers hold nothing, or hold it already.
 */
void
dbg_free(struct kproc *p)
{
	struct kdbg *d;
	struct kport *port;

	ipclock_enter();
	d = p->dbg;
	p->dbg = 0;
	port = d ? dbg_port(d) : 0;
	free(d);
	if (port)
		port_unref(port);
	ipclock_leave();
}

/* The debugger has gone. Marks only: disarming the target's hooks from
 * here would race a target running on another cpu, so dbg_settle does
 * it. Waking a parked one is what gets it to a cpu at all.
 */
void
dbg_mark_orphan(struct kproc *p)
{
	struct kdbg *d = p->dbg;

	if (!d || !dbg_orphaned(d))
		return;
	atomic_store_explicit(&d->detach, 1, memory_order_relaxed);

	/* tested and set under one hold, and re-asked every sweep: a proc
	 * that commits a stop in between would be marked and never woken,
	 * which is the stranding this exists to prevent.
	 */
	int wake;

	lock(&schedlock);
	wake = p->status == STOPPED;
	if (wake)
		p->status = READY;
	unlock(&schedlock);
	if (wake)
		make_ready(p);	/* the caller holds the bucket it wants */
}

/* Tell the debugger its target stopped. port_push wants the wide lock,
 * so callers hold it already or hold nothing.
 */
void
dbg_notify(struct kproc *p, int reason, int exited)
{
	struct kdbg *d = p->dbg;

	if (!d)
		return;

	struct kport *port = dbg_port(d);

	if (!port)
		return;

	struct wbuf w = { 0 };
	unsigned int npairs = exited ? 3 : 6;
	lua_Integer pid = p->id;
	lua_Integer line = d->stopline;
	lua_Integer co = dbg_coidx(p, d->stopco);
	const char *reasonstr = dbg_reasonstr(reason);
	const char *file = d->stopfile >= 0 ? d->file[d->stopfile] : "";
	unsigned int klen;

	if (wbyte(&w, 'B') || wput(&w, &npairs, 4))
		goto fail;

	klen = 3;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "dbg", 3) ||
	    wbyte(&w, 'I') || wput(&w, &pid, sizeof pid))
		goto fail;

	klen = 4;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "stop", 4))
		goto fail;
	klen = (unsigned int)strlen(reasonstr);
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, reasonstr, klen))
		goto fail;

	klen = 4;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "exit", 4) ||
	    wbyte(&w, exited ? 'T' : 'F'))
		goto fail;

	if (!exited) {
		klen = 4;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "line", 4) ||
		    wbyte(&w, 'I') || wput(&w, &line, sizeof line))
			goto fail;

		klen = 2;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "co", 2) ||
		    wbyte(&w, 'I') || wput(&w, &co, sizeof co))
			goto fail;

		klen = 4;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "file", 4))
			goto fail;
		klen = (unsigned int)strlen(file);
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, file, klen))
			goto fail;
	}

	/* npairs was written before the pairs, so a message that got this
	 * far has exactly the count it claims.
	 */
	if (port_push_owned(port, w.p, w.len, 0, 0, 0, 0))
		free(w.p);
	return;
fail:
	free(w.p);
}

static int
dbg_orphaned(struct kdbg *d)
{
	struct kport *port = dbg_port(d);

	if (!port || port->dead)
		return 1;
	return atomic_load_explicit(&port->nrecv, memory_order_relaxed) == 0;
}

/* the notice port, or 0 if gone. The pair is checked rather than a
 * pointer chased, as proc_selfport does.
 */
static struct kport *
dbg_port(struct kdbg *d)
{
	if (!d || !d->portgen)
		return 0;

	struct kport *port = portv[d->portidx];

	if (!port || port->gen != d->portgen)
		return 0;
	return port;
}

static void
dbg_push_status(lua_State *L, struct kproc *p)
{
	struct kdbg *d = p->dbg;

	lua_createtable(L, 0, 9);
	lua_pushboolean(L, d != 0);
	lua_setfield(L, -2, "attached");
	lua_pushboolean(L, p->status == STOPPED);
	lua_setfield(L, -2, "stopped");
	lua_pushboolean(L, p->status == BROKE);
	lua_setfield(L, -2, "broke");
	if (!d)
		return;
	lua_pushinteger(L, d->dbgpid);
	lua_setfield(L, -2, "debugger");
	lua_pushstring(L, dbg_reasonstr(d->reason));
	lua_setfield(L, -2, "reason");
	lua_pushinteger(L, d->nbp);
	lua_setfield(L, -2, "nbreak");
	if (p->status != STOPPED)
		return;
	lua_pushinteger(L, d->stopline);
	lua_setfield(L, -2, "line");
	lua_pushinteger(L, dbg_coidx(p, d->stopco));
	lua_setfield(L, -2, "co");
	if (d->stopfile >= 0) {
		lua_pushstring(L, d->file[d->stopfile]);
		lua_setfield(L, -2, "file");
	}
	if (d->stopbp) {
		lua_pushinteger(L, d->stopbp);
		lua_setfield(L, -2, "bp");
	}
}

/* the shared tail: the target's top is recorded OUTSIDE the pcall and
 * restored on every path, because the body pushes onto the target and
 * building the result can raise in the caller.
 */
static int
dbg_read(lua_State *L, struct dbgread *a)
{
	lua_State *co = dbg_costate(a->p, a->co);
	int top = co ? lua_gettop(co) : 0;

	lua_pushcfunction(L, dbg_read_body);
	lua_pushlightuserdata(L, a);

	int rc = lua_pcall(L, 1, 1, 0);

	if (co)
		lua_settop(co, top);
	proc_thaw(a->p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
dbg_read_body(lua_State *L)
{
	struct dbgread *a = lua_touserdata(L, 1);
	lua_State *co = dbg_costate(a->p, a->co);

	if (!co)
		return luaL_error(L, "no such coroutine");
	switch (a->root) {
	case -1:
		dbg_push_frames(L, co);
		return 1;
	case -2:
		dbg_push_locals(L, co, a->level);
		return 1;
	case -3:
		dbg_push_upvals(L, co, a->level);
		return 1;
	}
	if (!dbg_push_path(L, co, a->level, a->root, a->name, a->nlen,
	    a->path, a->npath))
		return 0;
	return 1;
}

/* make a stopped proc runnable again. The caller has thawed already:
 * make_ready takes schedlock, and so does proc_thaw.
 */
static void
dbg_resume(struct kproc *p)
{
	ipclock_enter();
	lock(&schedlock);
	p->status = READY;
	unlock(&schedlock);
	make_ready(p);
	ipclock_leave();
}

/* run_proc, on the cpu that owns this proc and before it is resumed:
 * the one place a debugger's state can be torn down safely, because
 * only here is it certain the target is running nowhere.
 */
void
dbg_settle(struct kproc *p)
{
	if (!p->dbg ||
	    !atomic_load_explicit(&p->dbg->detach, memory_order_relaxed))
		return;
	dbg_free(p);
	proc_rearm(p);		/* the mask loses LUA_MASKLINE with it */
}

static int
dbg_status_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);

	dbg_push_status(L, p);
	return 1;
}

/* Once per lap, holding nothing. Every cpu runs laps, so both halves
 * are claimed with an exchange; the wide lock is what port_push wants.
 */
void
dbg_sweep(void)
{
	for (int i = 0; i < prochigh; i++) {
		struct kproc *p = procv[i];

		/* the one unlocked read of the proc table: this runs on
		 * every lap of every cpu. Safe because proc_new zeroes a
		 * slot before publishing it, so dbg reads as a pointer or
		 * null, and it is read again under the lock below.
		 */
		if (!p || !p->dbg)
			continue;

		ipclock_enter();
		if (p->dbg) {
			int reason = atomic_exchange_explicit(
			    &p->dbg->notify, DBG_RUN, memory_order_relaxed);

			if (reason != DBG_RUN)
				dbg_notify(p, reason, 0);
			dbg_mark_orphan(p);
		}
		ipclock_leave();
	}
}

static int
api_dbg_attach(lua_State *L)
{
	return api_dbg_attach_k(L, LUA_OK, 0);
}

static int
api_dbg_attach_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *me = self(L);
	struct kproc *p;
	struct right *r = right_get(me, luaL_checkinteger(L, 2));

	(void)status;
	if (!r)
		return luaL_error(L, "bad right");

	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_attach_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	/* every failure below thaws before it raises: a raise past the
	 * thaw leaves the target frozen for good, which is worse than
	 * whatever was being refused.
	 */
	const char *err = 0;

	if (!may_debug(me, p))
		err = "no right to debug that proc";
	else if (p->dbg)
		err = "already attached";
	else if (p->torture)
		/* torture skips the walk-out for a nested state, so a stop
		 * requested there can never be committed. See preempt_hook.
		 */
		err = "proc is under sys.set_torture";
	else if (p->status == DEAD)
		err = "proc is dead";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = malloc(sizeof *d);

	if (!d) {
		proc_thaw(p);
		return luaL_error(L, "out of memory");
	}
	dbg_init(d, me->id);
	d->portidx = r->port->idx;
	d->portgen = r->port->gen;

	int orphan;

	/* the kernel's own reference, so the kport cannot be recycled
	 * under the (idx, gen) pair. Taken wide because dbg_free's
	 * matching unref is wide.
	 */
	ipclock_enter();
	orphan = atomic_load_explicit(&r->port->nrecv,
	    memory_order_relaxed) == 0 || r->port->dead;
	if (!orphan)
		r->port->nrights++;
	ipclock_leave();

	if (orphan) {
		free(d);
		proc_thaw(p);
		return luaL_error(L, "that right cannot be received on");
	}
	p->dbg = d;
	proc_thaw(p);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_dbg_breaks(lua_State *L)
{
	return api_dbg_breaks_k(L, LUA_OK, 0);
}

static int
api_dbg_breaks_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_breaks_k);
	case HOLD_SELF:
		return dbg_breaks_body(L);
	}

	lua_pushcfunction(L, dbg_breaks_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
api_dbg_clearbreak(lua_State *L)
{
	return api_dbg_clearbreak_k(L, LUA_OK, 0);
}

static int
api_dbg_clearbreak_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	lua_Integer id = luaL_optinteger(L, 2, 0);

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_clearbreak_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;
	int found = 0;

	for (int i = 0; i < d->nbp; i++) {
		if (id && d->bp[i].id != id)
			continue;
		found++;
		d->bp[i] = d->bp[--d->nbp];
		if (id)
			break;
		i--;
	}
	dbg_remask(d);
	proc_rearm(p);		/* the last one out takes LUA_MASKLINE */
	proc_thaw(p);
	lua_pushboolean(L, found != 0);
	return 1;
}

static int
api_dbg_cont(lua_State *L)
{
	return api_dbg_cont_k(L, LUA_OK, 0);
}

static int
api_dbg_cont_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_cont_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke: a corpse can be read, not resumed";
	if (!err && p->status != STOPPED)
		err = "proc is not stopped";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;

	d->step = STEP_NONE;
	d->stepco = 0;
	d->reason = DBG_RUN;
	d->stopco = 0;
	atomic_store_explicit(&d->pending, DBG_RUN, memory_order_relaxed);
	atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
	proc_rearm(p);		/* the mask may lose LUA_MASKLINE here */
	proc_thaw(p);
	dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_dbg_coros(lua_State *L)
{
	return api_dbg_coros_k(L, LUA_OK, 0);
}

static int
api_dbg_coros_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_coros_k);
	case HOLD_SELF:
		return dbg_coros_body(L);
	}

	lua_pushcfunction(L, dbg_coros_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
api_dbg_detach(lua_State *L)
{
	return api_dbg_detach_k(L, LUA_OK, 0);
}

static int
api_dbg_detach_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_detach_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), p)) {
		proc_thaw(p);
		return luaL_error(L, "no right to debug proc %d", p->id);
	}

	int wake = p->dbg && p->status == STOPPED;

	dbg_free(p);
	proc_rearm(p);
	proc_thaw(p);
	/* thawed first: make_ready wants the ipc lock and schedlock, and
	 * proc_thaw takes schedlock of its own.
	 */
	if (wake)
		dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_dbg_frames(lua_State *L)
{
	return api_dbg_frames_k(L, LUA_OK, 0);
}

static int
api_dbg_frames_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.root = -1;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_frames_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot read its own frames here");
	}
	return dbg_read(L, &a);
}

static int
api_dbg_get(lua_State *L)
{
	return api_dbg_get_k(L, LUA_OK, 0);
}

static int
api_dbg_get_k(lua_State *L, int status, lua_KContext ctx)
{
	/* rebuilt from the arguments on every re-entry, which is why a
	 * local is right: they are still on the stack, and a static would
	 * be shared with every other cpu.
	 */
	struct dbgread a = { 0 };
	const char *root = luaL_checkstring(L, 4);

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	if (!strcmp(root, "local"))
		a.root = DBGROOT_LOCAL;
	else if (!strcmp(root, "upvalue"))
		a.root = DBGROOT_UPVAL;
	else if (!strcmp(root, "global"))
		a.root = DBGROOT_GLOBAL;
	else
		return luaL_error(L, "root is local, upvalue or global");
	a.name = luaL_checklstring(L, 5, &a.nlen);

	if (!lua_isnoneornil(L, 6)) {
		luaL_checktype(L, 6, LUA_TTABLE);
		lua_Integer n = luaL_len(L, 6);

		if (n > DBGPATH)
			return luaL_error(L, "path too deep");
		for (lua_Integer i = 1; i <= n; i++) {
			struct dbgkey *k = &a.path[a.npath++];

			lua_rawgeti(L, 6, i);
			if (lua_type(L, -1) == LUA_TNUMBER) {
				k->kind = DBGKEY_INT;
				k->i = lua_tointeger(L, -1);
			} else if (lua_type(L, -1) == LUA_TSTRING) {
				k->kind = DBGKEY_STR;
				k->s = lua_tolstring(L, -1, &k->slen);
			} else {
				return luaL_error(L,
				    "a path key is a string or a number");
			}
			lua_pop(L, 1);
		}
	}

	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_get_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}

static int
api_dbg_locals(lua_State *L)
{
	return api_dbg_locals_k(L, LUA_OK, 0);
}

static int
api_dbg_locals_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	a.root = -2;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_locals_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}

static int
api_dbg_setbreak(lua_State *L)
{
	return api_dbg_setbreak_k(L, LUA_OK, 0);
}

static int
api_dbg_setbreak_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	const char *file = luaL_checkstring(L, 2);
	lua_Integer line = luaL_checkinteger(L, 3);

	(void)status;
	if (line <= 0)
		return luaL_error(L, "a breakpoint needs a line");

	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_setbreak_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);
	struct kdbg *d = p->dbg;

	if (!err && d->nbp >= DBGBP)
		err = "too many breakpoints";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	/* interning here rather than at the hit: a file the table has no
	 * room for is a breakpoint that would never match, and saying so
	 * now is better than never firing.
	 */
	int fileid = dbg_intern(d, 0, file);

	if (fileid < 0) {
		proc_thaw(p);
		return luaL_error(L, "too many source files");
	}

	struct kbp *b = &d->bp[d->nbp++];

	b->fileid = fileid;
	b->line = (int)line;
	b->enabled = 1;
	b->hits = 0;
	b->id = d->nextid++;
	dbg_remask(d);
	proc_rearm(p);		/* the mask gains LUA_MASKLINE with the first */
	proc_thaw(p);
	lua_pushinteger(L, b->id);
	return 1;
}

static int
api_dbg_status(lua_State *L)
{
	return api_dbg_status_k(L, LUA_OK, 0);
}

static int
api_dbg_status_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_status_k);
	case HOLD_SELF:
		dbg_push_status(L, p);
		return 1;
	}

	/* protected: the table is built in this proc's state, so it
	 * allocates, so it can raise -- and a raise past the thaw would
	 * leave the target frozen for good.
	 */
	lua_pushcfunction(L, dbg_status_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
api_dbg_step(lua_State *L)
{
	return api_dbg_step_k(L, LUA_OK, 0);
}

static int
api_dbg_step_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;
	const char *how = luaL_optstring(L, 2, "in");

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_step_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke: a corpse can be read, not resumed";
	if (!err && p->status != STOPPED)
		err = "proc is not stopped";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;
	int over = strcmp(how, "in") != 0;
	int alive = d->stopco && lua_status(d->stopco) == LUA_YIELD;

	if (over && alive) {
		d->step = STEP_OVER;
		d->stepco = d->stopco;
		d->stepdepth = dbg_depth(d->stopco);
		if (!strcmp(how, "out"))
			d->stepdepth--;
	} else {
		d->step = STEP_IN;
		d->stepco = 0;
	}
	d->reason = DBG_RUN;
	d->stopco = 0;
	atomic_store_explicit(&d->pending, DBG_RUN, memory_order_relaxed);
	atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
	proc_rearm(p);		/* the mask gains LUA_MASKLINE for the step */
	proc_thaw(p);
	dbg_resume(p);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_dbg_stop(lua_State *L)
{
	return api_dbg_stop_k(L, LUA_OK, 0);
}

static int
api_dbg_stop_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_stop_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}

	const char *err = dbg_acting(L, p);

	if (!err && p->status == BROKE)
		err = "proc is broke";
	if (!err && p->status == DEAD)
		err = "proc is dead";
	if (err) {
		proc_thaw(p);
		return luaL_error(L, "%s", err);
	}

	struct kdbg *d = p->dbg;

	if (p->status == STOPPED) {
		proc_thaw(p);
		lua_pushboolean(L, 1);
		return 1;
	}

	if (p->status == BLOCKED) {
		/* nothing to interrupt: park it here. Waiters stay linked
		 * and messages stay queued; the block continuation
		 * re-polls on continue.
		 */
		d->stopco = p->co;
		d->stopline = 0;
		d->stopfile = -1;
		d->reason = DBG_REQ;
		d->stopbp = 0;
		atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
		lock(&schedlock);
		p->status = STOPPED;
		unlock(&schedlock);
		atomic_store_explicit(&d->notify, DBG_REQ,
		    memory_order_relaxed);
		proc_thaw(p);
		lua_pushboolean(L, 1);
		return 1;
	}

	atomic_store_explicit(&d->stopreq, DBG_REQ, memory_order_relaxed);
	/* every coroutine, because the hook must fire wherever the proc
	 * is; hookforced = 2 is what puts the counts back afterwards.
	 * Legal only because proc_hold says no cpu is running the target.
	 */
	proc_armall(p, 1);
	p->hookforced = 2;
	proc_thaw(p);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_dbg_upvalues(lua_State *L)
{
	return api_dbg_upvalues_k(L, LUA_OK, 0);
}

static int
api_dbg_upvalues_k(lua_State *L, int status, lua_KContext ctx)
{
	struct dbgread a = { 0 };

	(void)status;
	a.co = (int)luaL_optinteger(L, 2, 1);
	a.level = (int)luaL_optinteger(L, 3, 0);
	a.root = -3;
	switch (proc_hold(L, 1, &a.p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_dbg_upvalues_k);
	case HOLD_SELF:
		return luaL_error(L, "a proc cannot debug itself");
	}
	if (!may_debug(self(L), a.p)) {
		proc_thaw(a.p);
		return luaL_error(L, "no right to debug proc %d", a.p->id);
	}
	return dbg_read(L, &a);
}


static const luaL_Reg kdbgapi[] = {
	{ "attach", api_dbg_attach },
	{ "detach", api_dbg_detach },
	{ "status", api_dbg_status },
	{ "stop", api_dbg_stop },
	{ "cont", api_dbg_cont },
	{ "step", api_dbg_step },
	{ "setbreak", api_dbg_setbreak },
	{ "clearbreak", api_dbg_clearbreak },
	{ "breaks", api_dbg_breaks },
	{ "frames", api_dbg_frames },
	{ "coros", api_dbg_coros },
	{ "locals", api_dbg_locals },
	{ "upvalues", api_dbg_upvalues },
	{ "get", api_dbg_get },
	{ 0, 0 }
};

int
luaopen_los_dbg(lua_State *L)
{
	luaL_newlib(L, kdbgapi);
	return 1;
}
