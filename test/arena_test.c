/* Two lua_States sharing one immutable object. Emits TAP.
 *
 * An arena object is permanently black, on no state's allgc list, and
 * points only at other arena objects. Those three keep the collector
 * off it with no change to mark, sweep or barrier code.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "lfunc.h"
#include "lgc.h"
#include "lapi.h"

/* Membership bit. maskgcbits covers bits 0-5, so a sweep and a
 * generational age reset both leave bit 7 set.
 */
#define ARENABIT	7

static int count, failed;

static int
ok(int cond, const char *name)
{
	count++;
	if (!cond)
		failed++;
	printf("%s %d - %s\n", cond ? "ok" : "not ok", count, name);
	fflush(stdout);
	return cond;
}

static void
diag(const char *fmt, ...)
{
	va_list ap;

	fputs("# ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
	fflush(stdout);
}

/* The arena: one static block, bump allocated. Static so the whole
 * region can be snapshotted and compared byte for byte.
 */

static char arena[16384];
static size_t arenaoff;

static void *
abump(size_t n)
{
	void *p;

	arenaoff = (arenaoff + 15u) & ~(size_t)15;	/* over-align */
	if (arenaoff + n > sizeof arena) {
		diag("arena exhausted");
		exit(1);
	}
	p = arena + arenaoff;
	arenaoff += n;
	memset(p, 0, n);
	return p;
}

/* Black, arena-tagged, no white bit. This is what the collector reads. */
static lu_byte
arenamark(void)
{
	return (lu_byte)(bitmask(BLACKBIT) | bitmask(ARENABIT));
}

/* Build an arena short string. Returns the TString.
 *
 * The seed is arbitrary: table lookup uses the hash stored in the
 * object, so any state can key on it. Only interning needs a fixed seed.
 */
static TString *
arena_str(const char *s)
{
	size_t l = strlen(s);
	TString *ts = abump(sizeof(TString) + l + 1);

	ts->tt = LUA_VSHRSTR;
	ts->marked = arenamark();
	ts->next = NULL;
	ts->extra = 0;
	ts->shrlen = (lu_byte)l;
	ts->hash = luaS_hash(s, l, 0x9e3779b9u);
	ts->u.hnext = NULL;
	memcpy(ts->contents, s, l + 1);
	return ts;
}

/* Compile a chunk and copy its Proto into the arena. Returns the copy.
 *
 * Constants, nested protos and debug info are dropped; this shape does
 * not use them. `source` is an arena string, so the Proto refers only
 * to arena objects.
 */
static Proto *
arena_proto(const char *chunk, TString *source)
{
	lua_State *B = luaL_newstate();
	Proto *f, *a;

	if (luaL_loadstring(B, chunk) != LUA_OK) {
		diag("builder: %s", lua_tostring(B, -1));
		exit(1);
	}
	f = clLvalue(s2v(B->top.p - 1))->p;

	a = abump(sizeof(Proto));
	a->tt = LUA_VPROTO;
	a->marked = arenamark();
	a->next = NULL;
	a->numparams = f->numparams;
	a->is_vararg = f->is_vararg;
	a->maxstacksize = f->maxstacksize;
	a->sizecode = f->sizecode;
	a->code = abump((size_t)f->sizecode * sizeof(Instruction));
	memcpy(a->code, f->code, (size_t)f->sizecode * sizeof(Instruction));
	a->source = source;
	a->gclist = NULL;

	lua_close(B);
	return a;
}

static int
in_arena(void *p)
{
	return (char *)p >= arena && (char *)p < arena + sizeof arena;
}

/* ---- using arena objects from a state ---- */

/* Push a closure over an arena Proto. The closure itself is per-state
 * and on allgc; only the Proto is shared.
 */
static void
push_arena_closure(lua_State *L, Proto *p)
{
	LClosure *cl = luaF_newLclosure(L, 0);

	cl->p = p;
	setclLvalue2s(L, L->top.p, cl);
	api_incr_top(L);
}

static void
push_arena_string(lua_State *L, TString *ts)
{
	setsvalue2s(L, L->top.p, ts);
	api_incr_top(L);
}

/* Allocate hard, so the collector runs on its own.
 *
 * Each round stores an arena object into a table that is already
 * black. That is the barrier trigger, isblack(container) &&
 * iswhite(value), so an arena value must not fire it.
 */
static void
churn(lua_State *L, int rounds, Proto *p, TString *shared)
{
	int i;

	for (i = 0; i < rounds; i++) {
		lua_createtable(L, 8, 8);
		lua_pushinteger(L, i);
		lua_seti(L, -2, 1);
		lua_pushfstring(L, "garbage-%d-%d", i, i * 7);
		lua_seti(L, -2, 2);
		lua_pop(L, 1);

		lua_getglobal(L, "hold");
		if (i & 1)
			push_arena_string(L, shared);
		else
			push_arena_closure(L, p);
		lua_seti(L, -2, (i % 16) + 1);
		lua_pop(L, 1);
	}
}

int
main(void)
{
	static char snap[sizeof arena];
	TString *src, *shared;
	Proto *p;
	lua_State *A, *B;
	int r;

	printf("1..13\n");

	src = arena_str("=(arena)");
	shared = arena_str("arena-shared-key");
	p = arena_proto("return 42", src);

	diag("arena is %zu bytes: 1 proto, 2 strings", arenaoff);
	ok(in_arena(p) && in_arena(shared) && in_arena(src),
	    "arena objects live outside any state");

	/* No libraries: nothing here needs one. */
	A = luaL_newstate();
	B = luaL_newstate();

	/* the arena Proto is on neither state's allgc, and never was */
	{
		GCObject *o;
		int seen = 0;

		for (o = G(A)->allgc; o != NULL; o = o->next)
			if ((void *)o == (void *)p || (void *)o == (void *)shared)
				seen = 1;
		for (o = G(B)->allgc; o != NULL; o = o->next)
			if ((void *)o == (void *)p || (void *)o == (void *)shared)
				seen = 1;
		ok(!seen, "arena objects are on no state's allgc list");
	}

	/* both states run the shared code */
	push_arena_closure(A, p);
	ok(lua_pcall(A, 0, 1, 0) == LUA_OK && lua_tointeger(A, -1) == 42,
	    "state A calls the arena proto");
	lua_pop(A, 1);

	push_arena_closure(B, p);
	ok(lua_pcall(B, 0, 1, 0) == LUA_OK && lua_tointeger(B, -1) == 42,
	    "state B calls the arena proto");
	lua_pop(B, 1);

	/* the arena string as a table key in both states */
	lua_newtable(A);
	push_arena_string(A, shared);
	lua_pushstring(A, "value-in-A");
	lua_rawset(A, -3);
	lua_setglobal(A, "t");

	lua_newtable(B);
	push_arena_string(B, shared);
	lua_pushstring(B, "value-in-B");
	lua_rawset(B, -3);
	lua_setglobal(B, "t");

	/* eqshrstr is pointer identity, so a natively interned copy of the
	 * same content is a different key and the lookup misses. Shared
	 * interning is therefore required for correctness.
	 */
	lua_getglobal(A, "t");
	lua_pushstring(A, "arena-shared-key");	/* A's own copy */
	lua_rawget(A, -2);
	ok(lua_isnil(A, -1),
	    "a natively interned copy is a different key");
	lua_pop(A, 2);

	lua_getglobal(A, "t");
	push_arena_string(A, shared);
	lua_rawget(A, -2);
	ok(lua_type(A, -1) == LUA_TSTRING, "arena string keys its own entry in A");
	lua_pop(A, 2);

	lua_getglobal(B, "t");
	push_arena_string(B, shared);
	lua_rawget(B, -2);
	ok(lua_type(B, -1) == LUA_TSTRING, "arena string keys its own entry in B");
	lua_pop(B, 2);

	/* Keep a live closure in each state, so the collector traverses to
	 * the Proto on every cycle.
	 */
	push_arena_closure(A, p);
	lua_setglobal(A, "shared");
	push_arena_closure(B, p);
	lua_setglobal(B, "shared");

	/* The table churn() writes into. Collected once first, so it is
	 * black before the loops start.
	 */
	lua_newtable(A);
	lua_setglobal(A, "hold");
	lua_newtable(B);
	lua_setglobal(B, "hold");
	lua_gc(A, LUA_GCCOLLECT);
	lua_gc(B, LUA_GCCOLLECT);

	memcpy(snap, arena, sizeof arena);

	/* incremental, both states, interleaved */
	lua_gc(A, LUA_GCINC, 0, 0, 0);
	lua_gc(B, LUA_GCINC, 0, 0, 0);
	for (r = 0; r < 40; r++) {
		churn(A, 200, p, shared);
		churn(B, 200, p, shared);
		lua_gc(A, LUA_GCCOLLECT);
		lua_gc(B, LUA_GCCOLLECT);
	}
	ok(memcmp(snap, arena, sizeof arena) == 0,
	    "incremental gc, 40 full cycles in two states: arena unchanged");

	/* generational, which has its own age bits and sweep paths */
	lua_gc(A, LUA_GCGEN, 0, 0);
	lua_gc(B, LUA_GCGEN, 0, 0);
	for (r = 0; r < 40; r++) {
		churn(A, 200, p, shared);
		churn(B, 200, p, shared);
		lua_gc(A, LUA_GCSTEP, 0);
		lua_gc(B, LUA_GCSTEP, 0);
	}
	lua_gc(A, LUA_GCCOLLECT);
	lua_gc(B, LUA_GCCOLLECT);
	ok(memcmp(snap, arena, sizeof arena) == 0,
	    "generational gc, 40 stepped cycles in two states: arena unchanged");

	/* Checked apart from the memcmp, so a failure names the property. */
	ok(!iswhite(p) && !iswhite(shared) && !iswhite(src),
	    "arena objects never became white");
	ok(testbit(p->marked, ARENABIT) && testbit(shared->marked, ARENABIT),
	    "the arena bit survived every sweep and age reset");

	/* still callable after all that */
	lua_getglobal(A, "shared");
	ok(lua_pcall(A, 0, 1, 0) == LUA_OK && lua_tointeger(A, -1) == 42,
	    "arena proto still runs after 80 collections");
	lua_pop(A, 1);

	/* Proc teardown: closing a state must not free shared code. */
	lua_close(A);
	lua_close(B);
	ok(memcmp(snap, arena, sizeof arena) == 0,
	    "closing both states left the arena intact");

	if (failed)
		diag("%d of %d failed", failed, count);
	return failed != 0;
}
