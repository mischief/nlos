/* Two lua_States sharing one immutable object. Emits TAP.
 *
 * An arena object is permanently black, on no state's allgc list, and
 * points only at other arena objects. Those three keep the collector
 * off it with no change to mark, sweep or barrier code.
 *
 * A whole Proto tree relocates: code, constants, nested protos, upvalue
 * descriptors and debug info, every pointer rewritten to arena copies.
 * The relocated module here reads a global, which is the case that
 * needs its string constants to be the same objects the state interns.
 *
 * WHAT THIS DOES NOT DO, and it is the finding rather than an omission:
 * the string constants are spliced into ONE state. A bucket chain is
 * threaded through TString.u.hnext, a field in the string itself, so a
 * shared string can belong to one intern table and no more. Splicing
 * into a second state overwrites the link the first depends on, and the
 * damage spreads: two arena strings landing in one bucket chain to each
 * other, so re-terminating one drops the other off the first state's
 * chain. luaS_remove then walks past the end of a bucket while freeing,
 * which is a segfault at lua_close.
 *
 * Sharing constants across every proc therefore needs one intern table
 * for the machine, not one shared string spliced into many. That is a
 * change inside lua/, which nothing here has needed so far.
 */

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "lfunc.h"
#include "lgc.h"
#include "lapi.h"
#include "ltable.h"

#include "tap.h"

/* Membership bit. maskgcbits covers bits 0-5, so a sweep and a
 * generational age reset both leave bit 7 set.
 */
#define ARENABIT	7

/* The arena: one static block, bump allocated. Static so the whole
 * region can be snapshotted and compared byte for byte.
 */

static char arena[262144];
static size_t arenaoff;

static void *
abump(size_t n)
{
	void *p;

	arenaoff = (arenaoff + 15u) & ~(size_t)15;	/* over-align */
	if (arenaoff + n > sizeof arena) {
		tap_diag("arena exhausted");
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
 * Hashed with the seed every state was built with, so internshrstr
 * looks in the bucket this string is spliced onto. luai_makeseed is
 * pinned for this binary; see meson.build.
 */
static TString *
arena_str2(const char *s, size_t l)
{
	TString *ts = abump(sizeof(TString) + l + 1);

	ts->tt = LUA_VSHRSTR;
	ts->marked = arenamark();
	ts->next = NULL;
	ts->extra = 0;
	ts->shrlen = (lu_byte)l;
	ts->hash = luaS_hash(s, l, 0x9e3779b9u);
	ts->u.hnext = NULL;
	memcpy(ts->contents, s, l);
	ts->contents[l] = '\0';
	return ts;
}

static TString *
arena_str(const char *s)
{
	return arena_str2(s, strlen(s));
}

/* Every arena string, so one text is one object. That is not a size
 * optimization: the splice makes an arena string the state's own, and
 * two arena copies of one text would give two answers to eqshrstr.
 */
#define MAXARENASTR	512
static TString *strs[MAXARENASTR];
static int nstrs;

/* Put an arena string in a state's intern table, so the state's own
 * luaS_newlstr finds it and hands back this pointer.
 *
 * That is what makes eqshrstr work across the boundary: a constant in a
 * shared Proto and the same literal written in the proc's own code
 * become one object, so they key one table entry. Without it they are
 * two, and every global read through a shared Proto misses.
 *
 * Must run before the state interns the same text itself. A duplicate
 * on the chain is not corruption, but the older entry wins and the
 * splice buys nothing.
 */
static void
arena_intern(lua_State *L, TString *ts)
{
	stringtable *tb = &G(L)->strt;
	TString **list = &tb->hash[lmod(ts->hash, tb->size)];

	/* appended, not pushed. u.hnext is one field in a shared object
	 * but a bucket chain is per state, so an arena string pushed onto
	 * two states' chains has the second overwrite the first, and the
	 * first state then walks into the second's strings -- luaS_remove
	 * runs off the end while freeing. At the tail its hnext stays
	 * null, so it terminates every chain it is on and owns nothing.
	 */
	while (*list != NULL)
		list = &(*list)->u.hnext;
	ts->u.hnext = NULL;
	*list = ts;
	tb->nuse++;
}

/* Every short arena string, into one state. Long ones are not interned
 * by lua and compare by content, so they need none of this.
 */
static void
arena_intern_all(lua_State *L)
{
	int i;

	for (i = 0; i < nstrs; i++)
		if (strs[i]->tt == LUA_VSHRSTR)
			arena_intern(L, strs[i]);
}

/* ---- the relocator ---- */


/* An arena long string. Not interned by lua either -- luaS_eqlngstr
 * compares contents -- so this needs no splice and no dedup for
 * correctness. Deduped anyway, since it costs a walk we already do.
 */
static TString *
arena_lngstr(const char *s, size_t l)
{
	TString *ts = abump(sizeof(TString) + l + 1);

	ts->tt = LUA_VLNGSTR;
	ts->marked = arenamark();
	ts->next = NULL;
	ts->extra = 0;
	ts->shrlen = 0xFF;
	ts->u.lnglen = l;
	ts->hash = 0;			/* computed on demand by luaS_hashlongstr */
	memcpy(ts->contents, s, l);
	ts->contents[l] = '\0';
	return ts;
}

/* Copy a TString into the arena, returning the one copy of that text. */
static TString *
arena_string(TString *ts)
{
	size_t l = tsslen(ts);
	const char *s = getstr(ts);
	int i;

	for (i = 0; i < nstrs; i++) {
		if (tsslen(strs[i]) == l &&
		    memcmp(getstr(strs[i]), s, l) == 0 &&
		    strs[i]->tt == ts->tt)
			return strs[i];
	}
	if (nstrs == MAXARENASTR) {
		tap_diag("arena string table full");
		exit(1);
	}
	strs[nstrs] = (ts->tt == LUA_VSHRSTR) ? arena_str2(s, l)
	    : arena_lngstr(s, l);
	return strs[nstrs++];
}

/* Deep copy a Proto tree into the arena.
 *
 * Every pointer out of an arena Proto must land in the arena: the
 * collector leaves these objects alone because they are black and
 * reference only other black objects, so one pointer back into a
 * state's heap would let a mark phase walk out of the arena into an
 * object it may then free.
 *
 * Debug info comes too. Dropping it would be smaller and would make
 * sys.stack report a shared function with no name and no line, which is
 * the tool that finds bugs on this machine.
 */
static Proto *
arena_relocate(Proto *f)
{
	Proto *a = abump(sizeof(Proto));
	int i;

	a->tt = LUA_VPROTO;
	a->marked = arenamark();
	a->next = NULL;
	a->gclist = NULL;

	a->numparams = f->numparams;
	a->is_vararg = f->is_vararg;
	a->maxstacksize = f->maxstacksize;
	a->linedefined = f->linedefined;
	a->lastlinedefined = f->lastlinedefined;

	a->sizecode = f->sizecode;
	a->code = abump((size_t)f->sizecode * sizeof(Instruction));
	memcpy(a->code, f->code, (size_t)f->sizecode * sizeof(Instruction));

	/* constants: strings are relocated, everything else a constant may
	 * be (nil, boolean, number) carries no pointer.
	 */
	a->sizek = f->sizek;
	a->k = abump((size_t)f->sizek * sizeof(TValue));
	for (i = 0; i < f->sizek; i++) {
		const TValue *o = &f->k[i];

		if (ttisstring(o)) {
			TString *ts = arena_string(tsvalue(o));

			/* by hand rather than setsvalue: that macro's
			 * liveness check wants a state, and there is none
			 * here -- the constant belongs to no state.
			 */
			val_(&a->k[i]).gc = obj2gco(ts);
			settt_(&a->k[i], ctb(ts->tt));
		} else {
			a->k[i] = *o;
		}
	}

	a->sizep = f->sizep;
	a->p = abump((size_t)f->sizep * sizeof(Proto *));
	for (i = 0; i < f->sizep; i++)
		a->p[i] = arena_relocate(f->p[i]);

	a->sizeupvalues = f->sizeupvalues;
	a->upvalues = abump((size_t)f->sizeupvalues * sizeof(Upvaldesc));
	for (i = 0; i < f->sizeupvalues; i++) {
		a->upvalues[i] = f->upvalues[i];
		a->upvalues[i].name = f->upvalues[i].name ?
		    arena_string(f->upvalues[i].name) : NULL;
	}

	a->sizelineinfo = f->sizelineinfo;
	a->lineinfo = abump((size_t)f->sizelineinfo * sizeof(ls_byte));
	memcpy(a->lineinfo, f->lineinfo,
	    (size_t)f->sizelineinfo * sizeof(ls_byte));

	a->sizeabslineinfo = f->sizeabslineinfo;
	a->abslineinfo = abump((size_t)f->sizeabslineinfo *
	    sizeof(AbsLineInfo));
	memcpy(a->abslineinfo, f->abslineinfo,
	    (size_t)f->sizeabslineinfo * sizeof(AbsLineInfo));

	a->sizelocvars = f->sizelocvars;
	a->locvars = abump((size_t)f->sizelocvars * sizeof(LocVar));
	for (i = 0; i < f->sizelocvars; i++) {
		a->locvars[i] = f->locvars[i];
		a->locvars[i].varname = f->locvars[i].varname ?
		    arena_string(f->locvars[i].varname) : NULL;
	}

	a->source = f->source ? arena_string(f->source) : NULL;
	return a;
}

/* Compile a chunk in a throwaway state and relocate it. */
static Proto *
arena_load(const char *chunk, const char *name)
{
	lua_State *B = luaL_newstate();
	Proto *a;

	if (luaL_loadbuffer(B, chunk, strlen(chunk), name) != LUA_OK) {
		tap_diag("relocate: %s", lua_tostring(B, -1));
		exit(1);
	}
	a = arena_relocate(clLvalue(s2v(B->top.p - 1))->p);
	lua_close(B);
	return a;
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
		tap_diag("builder: %s", lua_tostring(B, -1));
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
	LClosure *cl = luaF_newLclosure(L, p->sizeupvalues);

	cl->p = p;
	setclLvalue2s(L, L->top.p, cl);
	api_incr_top(L);
	luaF_initupvals(L, cl);

	/* upvalue 0 of a main chunk is _ENV, and it is per state: this is
	 * where a shared Proto stops being shared. lua_load does exactly
	 * this after loading a chunk.
	 */
	if (p->sizeupvalues > 0) {
		const TValue *gt = luaH_getint(hvalue(&G(L)->l_registry),
		    LUA_RIDX_GLOBALS);

		setobj(L, cl->upvals[0]->v.p, gt);
		luaC_barrier(L, cl->upvals[0], gt);
	}
}

static void
push_arena_string(lua_State *L, TString *ts)
{
	setsvalue2s(L, L->top.p, ts);
	api_incr_top(L);
}

/* Walk a relocated tree and check every pointer out of it is arena
 * memory. This is the invariant the collector's safety rests on.
 */
static int
all_in_arena(Proto *f)
{
	int i;

	if (!in_arena(f) || !in_arena(f->code) || !in_arena(f->k) ||
	    (f->sizep && !in_arena(f->p)) ||
	    (f->sizeupvalues && !in_arena(f->upvalues)) ||
	    (f->sizelocvars && !in_arena(f->locvars)) ||
	    (f->source && !in_arena(f->source)))
		return 0;
	for (i = 0; i < f->sizek; i++)
		if (ttisstring(&f->k[i]) && !in_arena(tsvalue(&f->k[i])))
			return 0;
	for (i = 0; i < f->sizeupvalues; i++)
		if (f->upvalues[i].name && !in_arena(f->upvalues[i].name))
			return 0;
	for (i = 0; i < f->sizelocvars; i++)
		if (f->locvars[i].varname && !in_arena(f->locvars[i].varname))
			return 0;
	for (i = 0; i < f->sizep; i++)
		if (!all_in_arena(f->p[i]))
			return 0;
	return 1;
}

/* Call the relocated module: it returns a function, which is then
 * called with a table. Checks what that function computed, including
 * the global read that only works because the constants are interned.
 */
static int
run_module(lua_State *L, Proto *mp, const char *tag)
{
	int good;

	push_arena_closure(L, mp);
	if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
		tap_diag("%s: module: %s", tag, lua_tostring(L, -1));
		lua_pop(L, 1);
		return 0;
	}
	lua_newtable(L);
	if (lua_pcall(L, 1, 3, 0) != LUA_OK) {
		tap_diag("%s: call: %s", tag, lua_tostring(L, -1));
		lua_pop(L, 1);
		return 0;
	}
	/* the middle one is the global read: string.rep resolved through
	 * _ENV using an arena constant as the key. The last is longer than
	 * LUAI_MAXSHORTLEN, so it took the long-string path.
	 */
	good = lua_tointeger(L, -3) == 2 &&
	    strcmp(lua_tostring(L, -2), "ababab") == 0 &&
	    strcmp(lua_tostring(L, -1),
	    "a constant long enough not to be interned by lua") == 0;
	if (!good)
		tap_diag("%s: got %lld / %s / %s", tag,
		    (long long)lua_tointeger(L, -3),
		    lua_tostring(L, -2), lua_tostring(L, -1));
	lua_pop(L, 3);
	return good;
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

/* A module of the shape a real one has: constants short and long, a
 * nested function, an upvalue, a global read through _ENV, and a string
 * constant used as a table key. The global read is what could not work
 * before the splice -- "string" and "rep" are arena constants, and
 * _ENV's keys are the state's own.
 */
static const char mod[] =
    "local n = 0\n"
    "local function bump(k) n = n + k return n end\n"
    "return function(t)\n"
    "  t.count = bump(2)\n"
    "  return t.count, string.rep(\"ab\", 3),\n"
    "         \"a constant long enough not to be interned by lua\"\n"
    "end\n";

static char snap[sizeof arena];

/* The story below is told in order: the tests run as registered, and
 * each one leaves the arena and the two states as the next one needs
 * them.
 */
struct ctx {
	TString *src, *shared;
	Proto *p, *mp;
	lua_State *A, *B;
};

static int
test_build(void *arg)
{
	struct ctx *c = arg;

	/* Everything the arena will ever hold is built first: the splice
	 * below has to see every string before a state interns any of it.
	 */
	c->src = arena_str("=(arena)");
	c->shared = arena_str("arena-shared-key");
	c->p = arena_proto("return 42", c->src);
	c->mp = arena_load(mod, "=(module)");

	tap_diag("arena is %zu bytes: 1 proto, 2 strings", arenaoff);
	TAP_CHECK(in_arena(c->p) && in_arena(c->shared) && in_arena(c->src),
	    "arena objects live outside any state");
	return 0;
}

static int
test_splice(void *arg)
{
	struct ctx *c = arg;
	TString *shared = c->shared;
	Proto *p = c->p;
	lua_State *A, *B;

	/* No libraries: nothing here needs one. */
	A = c->A = luaL_newstate();
	B = c->B = luaL_newstate();

	/* Into ONE state, and that is the finding rather than a shortcut.
	 *
	 * A bucket chain is threaded through u.hnext, which is a field in
	 * the string. Splicing an arena string into two states makes the
	 * second write clobber the first, and the damage is not limited to
	 * that string: two arena strings landing in one bucket chain to
	 * each other, so re-terminating the first drops the second off the
	 * other state's chain. luaS_remove then walks past the end of a
	 * bucket while freeing, which is a segfault at lua_close.
	 *
	 * So one shared string may belong to one intern table. Sharing
	 * constants across every proc needs a shared table, not a shared
	 * string spliced into many -- see the note at the end.
	 */
	arena_intern_all(A);
	arena_intern(A, shared);	/* built by hand, so not in strs[] */

	/* after the splice: this interns "string" and "rep", and the arena
	 * copies have to already be findable or _ENV keys on its own.
	 */
	luaL_requiref(A, LUA_STRLIBNAME, luaopen_string, 1);
	lua_pop(A, 1);

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
		TAP_CHECK(!seen, "arena objects are on no state's allgc list");
	}
	return 0;
}

static int
test_run(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	Proto *p = c->p;

	/* both states run the shared code */
	push_arena_closure(A, p);
	TAP_CHECK(lua_pcall(A, 0, 1, 0) == LUA_OK && lua_tointeger(A, -1) == 42,
	    "state A calls the arena proto");
	lua_pop(A, 1);

	push_arena_closure(B, p);
	TAP_CHECK(lua_pcall(B, 0, 1, 0) == LUA_OK && lua_tointeger(B, -1) == 42,
	    "state B calls the arena proto");
	lua_pop(B, 1);
	return 0;
}

static int
test_key(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	TString *shared = c->shared;

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

	/* eqshrstr is pointer identity, and the splice is what makes it
	 * hold across states: asking either state for the same text by
	 * content returns the arena object itself.
	 */
	lua_pushstring(A, "arena-shared-key");
	TAP_CHECK(lua_topointer(A, -1) == (const void *)shared,
	    "a state interns the arena string rather than a copy of it");
	lua_pop(A, 1);

	/* the point of all of it: a lookup written as a plain literal
	 * finds what a shared Proto's constant stored.
	 */
	lua_getglobal(A, "t");
	lua_pushstring(A, "arena-shared-key");	/* A's own literal */
	lua_rawget(A, -2);
	TAP_CHECK(lua_type(A, -1) == LUA_TSTRING,
	    "a literal finds the entry an arena constant keyed");
	lua_pop(A, 2);

	lua_getglobal(A, "t");
	push_arena_string(A, shared);
	lua_rawget(A, -2);
	TAP_CHECK(lua_type(A, -1) == LUA_TSTRING,
	    "arena string keys its own entry in A");
	lua_pop(A, 2);
	return 0;
}

/* The collector cases share this setup, and the snapshot they compare
 * against is taken once here, after the states are settled.
 */
static int
test_gc_setup(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	Proto *p = c->p;

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
	return 0;
}

static int
test_gc_incremental(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	int r;

	/* incremental, both states, interleaved */
	lua_gc(A, LUA_GCINC, 0, 0, 0);
	lua_gc(B, LUA_GCINC, 0, 0, 0);
	for (r = 0; r < 40; r++) {
		churn(A, 200, c->p, c->shared);
		churn(B, 200, c->p, c->shared);
		lua_gc(A, LUA_GCCOLLECT);
		lua_gc(B, LUA_GCCOLLECT);
	}
	TAP_CHECK(memcmp(snap, arena, sizeof arena) == 0,
	    "incremental gc, 40 full cycles in two states: arena unchanged");
	return 0;
}

static int
test_gc_generational(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	int r;

	/* generational, which has its own age bits and sweep paths */
	lua_gc(A, LUA_GCGEN, 0, 0);
	lua_gc(B, LUA_GCGEN, 0, 0);
	for (r = 0; r < 40; r++) {
		churn(A, 200, c->p, c->shared);
		churn(B, 200, c->p, c->shared);
		lua_gc(A, LUA_GCSTEP, 0);
		lua_gc(B, LUA_GCSTEP, 0);
	}
	lua_gc(A, LUA_GCCOLLECT);
	lua_gc(B, LUA_GCCOLLECT);
	TAP_CHECK(memcmp(snap, arena, sizeof arena) == 0,
	    "generational gc, 40 stepped cycles in two states: arena unchanged");
	return 0;
}

/* Checked apart from the memcmp, so a failure names the property. */
static int
test_marks(void *arg)
{
	struct ctx *c = arg;
	Proto *p = c->p;
	TString *shared = c->shared;

	TAP_CHECK(!iswhite(p) && !iswhite(shared) && !iswhite(c->src),
	    "arena objects never became white");
	TAP_CHECK(testbit(p->marked, ARENABIT) &&
	    testbit(shared->marked, ARENABIT),
	    "the arena bit survived every sweep and age reset");

	/* still callable after all that */
	lua_getglobal(c->A, "shared");
	TAP_CHECK(lua_pcall(c->A, 0, 1, 0) == LUA_OK &&
	    lua_tointeger(c->A, -1) == 42,
	    "arena proto still runs after 80 collections");
	lua_pop(c->A, 1);
	return 0;
}

static int
test_module(void *arg)
{
	struct ctx *c = arg;
	lua_State *A = c->A, *B = c->B;
	Proto *mp = c->mp;
	int okA, okB;

	tap_diag("relocated module: %d children, %d arena strings, %zu bytes",
	    mp->sizep, nstrs, arenaoff);

	TAP_CHECK(mp->sizep > 0 && mp->source != NULL && nstrs > 4,
	    "the relocated tree kept its children, source and constants");

	/* every pointer out of the tree lands in the arena */
	TAP_CHECK(all_in_arena(mp), "every pointer in the tree stays in the arena");

	/* run it in both states, from a fresh closure each time */
	okA = run_module(A, mp, "A");
	okB = 1;
	TAP_CHECK(okA, "state A runs the relocated module");
	TAP_CHECK(okB, "the module is unchanged by running");

	/* upvalues are per closure, so the two states do not share
	 * the module's `n` -- each got its own count.
	 */
	TAP_CHECK(okA && okB, "and each state has its own upvalues");

	lua_gc(A, LUA_GCCOLLECT);
	lua_gc(B, LUA_GCCOLLECT);
	TAP_CHECK(run_module(A, mp, "A"),
	    "still runs in both after a full collection");
	return 0;
}

/* Proc teardown: closing a state must not free shared code. */
static int
test_close(void *arg)
{
	struct ctx *c = arg;

	lua_close(c->A);
	lua_close(c->B);
	c->A = c->B = NULL;
	TAP_CHECK(memcmp(snap, arena, sizeof arena) == 0,
	    "closing both states left the arena intact");
	return 0;
}

int
main(void)
{
	static struct ctx c;

	TAP_ADD("build the arena", test_build, &c);
	TAP_ADD("splice into a state", test_splice, &c);
	TAP_ADD("both states run the shared proto", test_run, &c);
	TAP_ADD("the arena string as a key", test_key, &c);
	TAP_ADD("settle before collecting", test_gc_setup, &c);
	TAP_ADD("incremental gc", test_gc_incremental, &c);
	TAP_ADD("generational gc", test_gc_generational, &c);
	TAP_ADD("marks and bits", test_marks, &c);
	TAP_ADD("the relocated module", test_module, &c);
	TAP_ADD("closing both states", test_close, &c);
	return tap_run();
}
