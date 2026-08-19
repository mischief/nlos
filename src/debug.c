/* debug.c: read another proc's stacks without disturbing it.
 *
 * sys.stack(pid) used to walk one coroutine -- the proc's main one --
 * which for anything built on lib/thread is the SCHEDULER. Every such
 * proc reported the same three frames, alt / thread.run /
 * entrypoint, whether it was idle or deadlocked, so the one question
 * worth asking a stuck proc was the one it could not answer.
 *
 * The threads are coroutines inside that proc's lua_State, and a
 * coroutine cannot be handed across states -- debug.traceback only sees
 * its own. So finding them has to happen here, in C, holding the
 * target's lua_State directly.
 *
 * ---- the rules this file keeps, and why ----
 *
 * Introspection must not become participation. A debugger that perturbs
 * the thing it looks at is worse than none, because the report is then
 * about a machine that no longer exists.
 *
 *   1. NEVER run target code. lua_next, lua_rawget and lua_rawgeti only.
 *      Not lua_getfield or lua_gettable, which fire __index; not
 *      luaL_tolstring, which fires __tostring; not lua_tostring on a
 *      number, which rewrites the stack slot in place. lua_getinfo with
 *      "Sln" pushes nothing and calls nothing -- "f" and "L" would push,
 *      so they are not asked for.
 *
 *   2. NEVER allocate in the target. The visited set is a C array of
 *      pointers in OUR frame rather than a table in theirs: a table
 *      would be charged to their mem_limit, so debugging a proc near its
 *      cap could push it over, which is a memorable way to lose the
 *      thing you were inspecting. The walk starts at LUA_RIDX_GLOBALS
 *      via lua_rawgeti, which pushes a value that already exists;
 *      package.loaded is reachable from globals, so no string ever has
 *      to be pushed to look a module up either.
 *
 *   3. LEAVE THE STACK AS FOUND. Every path restores the recorded top,
 *      and lua_checkstack is asked first -- it returns 0 rather than
 *      raising, which matters because raising inside the TARGET state
 *      from a call made by another proc would unwind a stack that is not
 *      ours.
 *
 * What this misses, and it is worth knowing rather than discovering: a
 * coroutine referenced only from a C closure's upvalue or a live local
 * is not reachable from globals and will not be found. For a scheduler
 * that is not a real case -- one that cannot reach its own threads has
 * already lost them -- and the alternative was walking the GC's object
 * lists, which means lstate.h, internal layout, and separate handling
 * for finobj and the generational lists. Public API is worth the gap.
 *
 * Safe to call on any proc because every proc but the caller is
 * suspended between resumes; there is no moment at which a stack is
 * half-built.
 */

#include <stddef.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "debug.h"

/* Bounds, all of them deliberate: a proc under inspection may have
 * whatever shape it likes, including a cyclic one, and this runs inside
 * a kernel call.
 */
#define MAXCOROS	16	/* coroutines reported */
/* 256 pointers is 2KB of stack, and the kernel caps a frame at 4KB. It
 * is also far more than the walk needs: from globals at depth 6 the
 * reachable table count is in the dozens.
 */
#define MAXSEEN		256	/* tables remembered, so cycles terminate */
#define MAXDEPTH	6	/* globals -> package -> loaded -> mod -> t -> co */
#define MAXFRAMES	32	/* frames per coroutine */

struct walk {
	lua_State *found[MAXCOROS];
	int nfound;
	const void *seen[MAXSEEN];
	int nseen;
};

static int
already_seen(struct walk *w, const void *p)
{
	for (int i = 0; i < w->nseen; i++)
		if (w->seen[i] == p)
			return 1;
	if (w->nseen < MAXSEEN)
		w->seen[w->nseen++] = p;
	return 0;
}

static void
remember(struct walk *w, lua_State *co)
{
	for (int i = 0; i < w->nfound; i++)
		if (w->found[i] == co)
			return;
	if (w->nfound < MAXCOROS)
		w->found[w->nfound++] = co;
}

/* Traverse the table on top of T's stack. Leaves the stack as found. */
static void
walk_table(lua_State *T, struct walk *w, int depth)
{
	if (depth > MAXDEPTH || w->nfound >= MAXCOROS)
		return;
	if (already_seen(w, lua_topointer(T, -1)))
		return;
	if (!lua_checkstack(T, 4))
		return;

	lua_pushnil(T);
	while (lua_next(T, -2) != 0) {
		/* key at -2, value at -1 */
		int kt = lua_type(T, -2);
		int vt = lua_type(T, -1);

		if (vt == LUA_TTHREAD)
			remember(w, lua_tothread(T, -1));
		else if (vt == LUA_TTABLE)
			walk_table(T, w, depth + 1);

		/* Keys matter as much as values, and not hypothetically:
		 * lib/thread._parked is keyed BY COROUTINE, so a parked
		 * thread appears only as a key. Checking values alone found
		 * nothing at all in an sshd whose threads were both parked
		 * -- which is every proc worth looking at with this.
		 */
		if (kt == LUA_TTHREAD) {
			remember(w, lua_tothread(T, -2));
		} else if (kt == LUA_TTABLE) {
			lua_pushvalue(T, -2);
			walk_table(T, w, depth + 1);
			lua_pop(T, 1);
		}

		lua_pop(T, 1);		/* value; key stays for lua_next */
	}
}

/* Collect coroutines reachable from the target's globals and registry.
 *
 * The registry is a root of its own: src/thread.c holds the run ring
 * and the park table as registry refs, which no path from _G reaches.
 */
static void
collect(lua_State *T, struct walk *w)
{
	int top = lua_gettop(T);

	if (!lua_checkstack(T, 4))
		return;

	lua_rawgeti(T, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
	if (lua_type(T, -1) == LUA_TTABLE)
		walk_table(T, w, 0);
	lua_settop(T, top);

	lua_pushvalue(T, LUA_REGISTRYINDEX);
	walk_table(T, w, 0);
	lua_settop(T, top);
}

/* Push one coroutine's frames onto `to` as an array of tables. */
static void
push_frames(lua_State *to, lua_State *co)
{
	lua_Debug ar;
	int n = 0;

	lua_newtable(to);
	for (int level = 0; level < MAXFRAMES; level++) {
		if (!lua_getstack(co, level, &ar))
			break;
		/* "Sln" pushes nothing and runs nothing. */
		if (!lua_getinfo(co, "Sln", &ar))
			break;

		lua_createtable(to, 0, 4);
		lua_pushstring(to, ar.short_src);
		lua_setfield(to, -2, "source");
		lua_pushinteger(to, ar.currentline);
		lua_setfield(to, -2, "line");
		lua_pushstring(to, ar.name ? ar.name : "?");
		lua_setfield(to, -2, "name");
		lua_pushstring(to, ar.what ? ar.what : "?");
		lua_setfield(to, -2, "what");
		lua_rawseti(to, -2, ++n);
	}
}

static const char *
costatus(lua_State *co, lua_State *main)
{
	if (co == main)
		return "main";
	switch (lua_status(co)) {
	case LUA_OK:
		/* An OK coroutine with frames has been started and is
		 * suspended inside a call; one with none never ran.
		 */
		return lua_getstack(co, 0, &(lua_Debug){ 0 }) ? "normal"
		    : "dead";
	case LUA_YIELD:
		return "suspended";
	default:
		return "error";
	}
}

/* Push an array of { label, status, frames } onto `to`: the proc's main
 * coroutine first, then every other one reachable from its globals.
 */
void
debug_push_stacks(lua_State *to, lua_State *target_main, lua_State *target_co)
{
	struct walk w = { .nfound = 0, .nseen = 0 };
	int n = 0;

	collect(target_main, &w);

	lua_newtable(to);

	/* the proc's own coroutine first, always, whether or not the walk
	 * happened to reach it
	 */
	lua_createtable(to, 0, 3);
	lua_pushstring(to, "main");
	lua_setfield(to, -2, "label");
	lua_pushstring(to, costatus(target_co, target_co));
	lua_setfield(to, -2, "status");
	push_frames(to, target_co);
	lua_setfield(to, -2, "frames");
	lua_rawseti(to, -2, ++n);

	for (int i = 0; i < w.nfound; i++) {
		/* "thread " plus an int that cannot exceed nfound, which a
		 * proc's coroutine count bounds. Sized for the widest int
		 * anyway, so the compiler need not take the author's word.
		 */
		char label[24];

		if (w.found[i] == target_co || w.found[i] == target_main)
			continue;

		snprintf(label, sizeof label, "thread %d", i + 1);

		lua_createtable(to, 0, 3);
		lua_pushstring(to, label);
		lua_setfield(to, -2, "label");
		lua_pushstring(to, costatus(w.found[i], target_main));
		lua_setfield(to, -2, "status");
		push_frames(to, w.found[i]);
		lua_setfield(to, -2, "frames");
		lua_rawseti(to, -2, ++n);
	}
}

/* ---- los.dbg: breakpoints, and reading a held proc ----
 * The rules above hold here, plus one: getlocal and getupvalue PUSH,
 * so every path restores the target's top.
 */

#define READFRAMES	64	/* frames reported per coroutine */
#define MAXLOCALS	64	/* locals or upvalues reported per frame */
#define MAXSCAN		4096	/* table entries scanned for one key */

void
dbg_init(struct kdbg *d, int dbgpid)
{
	memset(d, 0, sizeof *d);
	d->lastid = -1;
	d->stopfile = -1;
	d->step = STEP_NONE;
	d->nextid = 1;
	d->dbgpid = dbgpid;
}

const char *
dbg_reasonstr(int reason)
{
	switch (reason) {
	case DBG_REQ:	return "request";
	case DBG_BP:	return "breakpoint";
	case DBG_STEP:	return "step";
	case DBG_ENTRY:	return "entry";
	}
	return "run";
}

int
dbg_wants_lines(struct kdbg *d)
{
	return d && (d->nbp > 0 || d->step != STEP_NONE);
}

int
dbg_intern(struct kdbg *d, const void *srcptr, const char *name)
{
	if (srcptr && srcptr == d->lastsrc)
		return d->lastid;
	for (int i = 0; i < d->nfile; i++)
		if (!strcmp(d->file[i], name)) {
			d->lastsrc = srcptr;
			d->lastid = i;
			return i;
		}
	if (d->nfile >= DBGSRC)
		return -1;
	snprintf(d->file[d->nfile], LUA_IDSIZE, "%s", name);
	d->lastsrc = srcptr;
	d->lastid = d->nfile;
	return d->nfile++;
}

void
dbg_remask(struct kdbg *d)
{
	d->linemask = 0;
	for (int i = 0; i < d->nbp; i++)
		if (d->bp[i].enabled)
			d->linemask |= 1ull << (d->bp[i].line & 63);
}

int
dbg_depth(lua_State *L)
{
	lua_Debug ar;
	int n = 0;

	while (n < DBGDEPTH && lua_getstack(L, n, &ar))
		n++;
	return n;
}

void
dbg_arm_stop(struct kdbg *d, lua_State *L, lua_Debug *ar, int reason, int bp)
{
	/* "Sl" pushes nothing and calls nothing; "f" and "L" would */
	if (ar && lua_getinfo(L, "Sl", ar)) {
		d->stopline = ar->currentline;
		d->stopfile = dbg_intern(d, ar->source, ar->short_src);
	} else {
		d->stopline = 0;
		d->stopfile = -1;
	}
	d->stopco = L;
	d->stopbp = bp;
	d->reason = reason;
	d->step = STEP_NONE;
	d->stepco = 0;
	atomic_store_explicit(&d->stopreq, 0, memory_order_relaxed);
	/* release, and the fields above are why: dbg_commit picks this up
	 * and republishes it as notify, which is what another cpu's sweep
	 * reads the stop fields behind.
	 */
	atomic_store_explicit(&d->pending, reason, memory_order_release);
}

int
dbg_line(struct kdbg *d, lua_State *L, lua_Debug *ar)
{
	if (atomic_load_explicit(&d->pending, memory_order_relaxed))
		return 1;	/* a stop is already decided */

	if (d->step == STEP_IN) {
		dbg_arm_stop(d, L, ar, DBG_STEP, 0);
		return 1;
	}
	if (d->step == STEP_OVER) {
		/* the same coroutine, at or above the frame it started
		 * in: deeper is the call being stepped over.
		 */
		if (L != d->stepco || dbg_depth(L) > d->stepdepth)
			return 0;
		dbg_arm_stop(d, L, ar, DBG_STEP, 0);
		return 1;
	}
	if (!d->nbp)
		return 0;
	if (!(d->linemask & (1ull << (ar->currentline & 63))))
		return 0;	/* no breakpoint shares this line's low bits */

	/* "S" pushes nothing; from here the cache is a pointer compare */
	if (!lua_getinfo(L, "S", ar))
		return 0;

	int line = ar->currentline;

	for (int i = 0; i < d->nbp; i++) {
		struct kbp *b = &d->bp[i];

		if (!b->enabled || b->line != line)
			continue;
		if (b->fileid != dbg_intern(d, ar->source, ar->short_src))
			continue;
		b->hits++;
		dbg_arm_stop(d, L, ar, DBG_BP, b->id);
		return 1;
	}
	return 0;
}

/* Describe the value at `idx` on T, onto `to`. Scalars are copied;
 * anything else is type and address, since rendering it would mean
 * __tostring, which is target code.
 */
static void
push_desc(lua_State *to, lua_State *T, int idx)
{
	int t = lua_type(T, idx);

	lua_createtable(to, 0, 5);
	lua_pushstring(to, lua_typename(T, t));
	lua_setfield(to, -2, "t");

	switch (t) {
	case LUA_TNIL:
	case LUA_TNONE:
		return;
	case LUA_TBOOLEAN:
		lua_pushboolean(to, lua_toboolean(T, idx));
		lua_setfield(to, -2, "v");
		return;
	case LUA_TNUMBER:
		/* lua_tonumber, never lua_tostring: on a number that
		 * rewrites the target's stack slot in place.
		 */
		if (lua_isinteger(T, idx))
			lua_pushinteger(to, lua_tointeger(T, idx));
		else
			lua_pushnumber(to, lua_tonumber(T, idx));
		lua_setfield(to, -2, "v");
		return;
	case LUA_TSTRING: {
		size_t n;
		const char *s = lua_tolstring(T, idx, &n);

		/* safe on a string, which is already one; it is only on a
		 * number that this would convert in place.
		 */
		if (n > DBGSTRMAX) {
			lua_pushlstring(to, s, DBGSTRMAX);
			lua_pushboolean(to, 1);
			lua_setfield(to, -3, "trunc");
		} else {
			lua_pushlstring(to, s, n);
		}
		lua_setfield(to, -2, "v");
		return;
	}
	}

	/* No address for light userdata: a los.sys closure holds the
	 * kernel's lua_CFunction in one, and dbd1474 closed that leak.
	 * Flagged instead -- lua_typename calls both "userdata".
	 */
	if (t == LUA_TLIGHTUSERDATA) {
		lua_pushboolean(to, 1);
		lua_setfield(to, -2, "light");
		return;
	}

	lua_pushfstring(to, "%p", lua_topointer(T, idx));
	lua_setfield(to, -2, "addr");
	if (t != LUA_TTABLE)
		return;

	lua_pushinteger(to, (lua_Integer)lua_rawlen(T, idx));
	lua_setfield(to, -2, "n");
}

/* The keys of a table, so a caller knows what it may walk into. Raw:
 * lua_next fires no metamethod and pushes only values already there.
 */
static void
push_keys(lua_State *to, lua_State *T, int idx)
{
	int top = lua_gettop(T);
	int n = 0;

	if (!lua_checkstack(T, 4))
		return;
	lua_createtable(to, DBGKEYS, 0);
	idx = lua_absindex(T, idx);
	lua_pushnil(T);
	while (n < DBGKEYS && lua_next(T, idx)) {
		push_desc(to, T, -2);
		lua_rawseti(to, -2, ++n);
		lua_pop(T, 1);		/* value; key stays for lua_next */
	}
	if (n == DBGKEYS)
		lua_pop(T, 2);		/* the walk was cut short */
	lua_settop(T, top);
	lua_setfield(to, -2, "keys");
}

void
dbg_push_frames(lua_State *to, lua_State *co)
{
	int top = lua_gettop(co);
	int n = 0;

	lua_createtable(to, READFRAMES, 0);
	for (int level = 0; level < READFRAMES; level++) {
		lua_Debug ar;

		if (!lua_getstack(co, level, &ar))
			break;
		/* "Slnu" pushes nothing and calls nothing */
		if (!lua_getinfo(co, "Slnu", &ar))
			break;

		lua_createtable(to, 0, 6);
		lua_pushstring(to, ar.short_src);
		lua_setfield(to, -2, "source");
		lua_pushinteger(to, ar.currentline);
		lua_setfield(to, -2, "line");
		lua_pushstring(to, ar.name ? ar.name : "?");
		lua_setfield(to, -2, "name");
		lua_pushstring(to, ar.what ? ar.what : "?");
		lua_setfield(to, -2, "what");
		lua_pushinteger(to, ar.nups);
		lua_setfield(to, -2, "nups");
		lua_pushinteger(to, level);
		lua_setfield(to, -2, "level");
		lua_rawseti(to, -2, ++n);
	}
	lua_settop(co, top);
}

/* locals and upvalues differ only in how a slot is named and fetched */
static void
push_slots(lua_State *to, lua_State *co, int level, int upvals)
{
	int top = lua_gettop(co);
	lua_Debug ar;
	int n = 0;

	lua_createtable(to, MAXLOCALS, 0);
	if (!lua_checkstack(co, 4))
		return;
	if (!lua_getstack(co, level, &ar))
		return;
	if (upvals && (!lua_getinfo(co, "f", &ar) || !lua_isfunction(co, -1))) {
		lua_settop(co, top);
		return;
	}

	for (int i = 1; i <= MAXLOCALS; i++) {
		const char *name = upvals ? lua_getupvalue(co, -1, i)
		    : lua_getlocal(co, &ar, i);

		if (!name)
			break;

		lua_createtable(to, 0, 3);
		lua_pushstring(to, name);
		lua_setfield(to, -2, "name");
		/* names in parentheses are lua's own -- "(temporary)",
		 * "(for state)". Reported rather than hidden: a debugger
		 * that lies about the stack is worse than an ugly one.
		 */
		if (name[0] == '(') {
			lua_pushboolean(to, 1);
			lua_setfield(to, -2, "internal");
		}
		push_desc(to, co, -1);
		if (lua_type(co, -1) == LUA_TTABLE)
			push_keys(to, co, -1);
		lua_setfield(to, -2, "value");
		lua_rawseti(to, -2, ++n);
		lua_pop(co, 1);		/* the value we were handed */
	}
	lua_settop(co, top);
}

void
dbg_push_locals(lua_State *to, lua_State *co, int level)
{
	push_slots(to, co, level, 0);
}

void
dbg_push_upvals(lua_State *to, lua_State *co, int level)
{
	push_slots(to, co, level, 1);
}

/* Find one key of the table at the top of T and replace the table with
 * its value. Raw throughout, so __index never fires.
 */
static int
hop(lua_State *T, const struct dbgkey *k)
{
	if (!lua_istable(T, -1))
		return 0;
	if (k->kind == DBGKEY_INT) {
		/* allocation-free, unlike pushing a key */
		lua_rawgeti(T, -1, k->i);
		lua_remove(T, -2);
		return lua_type(T, -1) != LUA_TNIL;
	}

	/* A string key is scanned for rather than pushed: lua_pushstring
	 * would intern it in the target's heap and charge its mem_limit,
	 * so reading a proc could push it over its cap.
	 */
	int idx = lua_gettop(T);
	int n = 0;

	lua_pushnil(T);
	while (n++ < MAXSCAN && lua_next(T, idx)) {
		size_t klen;
		const char *ks;

		if (lua_type(T, -2) != LUA_TSTRING) {
			lua_pop(T, 1);
			continue;
		}
		ks = lua_tolstring(T, -2, &klen);
		if (klen == k->slen && !memcmp(ks, k->s, klen)) {
			lua_remove(T, -2);	/* the key */
			lua_remove(T, -2);	/* the table */
			return 1;
		}
		lua_pop(T, 1);
	}
	lua_settop(T, idx - 1);
	return 0;
}

/* the named local, upvalue or global of one frame, onto T's stack */
static int
push_root(lua_State *T, int level, int root, const char *name, size_t nlen)
{
	lua_Debug ar;

	if (root == DBGROOT_GLOBAL) {
		/* the table already exists, so it is pushed rather than
		 * made; the name is then scanned for, not pushed.
		 */
		struct dbgkey k = { DBGKEY_STR, name, nlen, 0 };

		lua_rawgeti(T, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
		if (!nlen)
			return 1;	/* the globals table itself */
		return hop(T, &k);
	}
	if (!lua_getstack(T, level, &ar))
		return 0;
	if (root == DBGROOT_UPVAL) {
		if (!lua_getinfo(T, "f", &ar) || !lua_isfunction(T, -1))
			return 0;
		for (int i = 1; i <= MAXLOCALS; i++) {
			const char *n = lua_getupvalue(T, -1, i);

			if (!n)
				break;
			if (strlen(n) == nlen && !memcmp(n, name, nlen)) {
				lua_remove(T, -2);	/* the function */
				return 1;
			}
			lua_pop(T, 1);
		}
		return 0;
	}
	for (int i = 1; i <= MAXLOCALS; i++) {
		const char *n = lua_getlocal(T, &ar, i);

		if (!n)
			break;
		if (strlen(n) == nlen && !memcmp(n, name, nlen))
			return 1;
		lua_pop(T, 1);
	}
	return 0;
}

int
dbg_push_path(lua_State *to, lua_State *co, int level, int root,
    const char *name, size_t nlen, const struct dbgkey *path, int npath)
{
	int top = lua_gettop(co);

	if (npath > DBGPATH)
		return 0;
	if (!lua_checkstack(co, 8))
		return 0;
	if (!push_root(co, level, root, name, nlen)) {
		lua_settop(co, top);
		return 0;
	}
	for (int i = 0; i < npath; i++)
		if (!hop(co, &path[i])) {
			lua_settop(co, top);
			return 0;
		}

	push_desc(to, co, -1);
	if (lua_type(co, -1) == LUA_TTABLE)
		push_keys(to, co, -1);
	lua_settop(co, top);
	return 1;
}
