/* debug.c: read another proc's stacks without disturbing it.
 *
 * sys.stack(pid) used to walk one coroutine -- the proc's main one --
 * which for anything built on lib/thread is the SCHEDULER. Every such
 * proc reported the same three frames, altblock / thread.run /
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

/* Collect coroutines reachable from the target's globals. */
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
		char label[16];

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
