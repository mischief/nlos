/* the proc lifecycle: making one, confining it, arming its hooks,
 * pacing its collector, and taking it apart again. see docs/proc.md.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <sys/queue.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "lock.h"
#include "cpu.h"
#include "buf.h"
#include "luaheap.h"
#include "debug.h"
#include "kernel.h"
#include "kproc.h"
#include "port.h"
#include "ksched.h"
#include "timer.h"
#include "proc.h"
#include "serialize.h"
#include "platform.h"

/* fallback if calibration fails; replaced at boot by a measured value. */
#define REDUCTIONS	25000

/* how much a proc must have allocated before its collector is stepped.
 * Below this the step costs more than it can recover: a proc that did
 * almost nothing in its slice has almost nothing to collect.
 */
#define GCSTEP_MIN	(16 * 1024)

/* how many corpses may be held at once.
 *
 * each one is a whole lua_State parked in the shared heap -- tens of
 * kilobytes that no live proc can use -- so this is a cache of recent
 * deaths, not a graveyard. breaking past the cap reaps the oldest, on
 * the theory that the death you are looking into is the one that just
 * happened.
 */
#define MAXBROKE	2

/* the largest step gc_step asks for, in kilobytes: enough to keep lua's
 * debt inside a 32-bit l_mem.
 */
#define GCSTEP_MAX_KB	(16 * 1024)

static int kernel_cowrap_resume(lua_State *L, lua_State *co, int narg);
static void preempt_hook(lua_State *L, lua_Debug *ar);
static void trace_put(struct kproc *p, struct ktrace *t, int line, int src,
    int co);
static void *kalloc_chunk(void *ud, size_t n);
static void kalloc_free_chunk(void *ud, void *p, size_t n);

/* the proc a lua_State belongs to, from its extra space. */
int	luaopen_los_thread(lua_State *L);	/* thread.c */

static struct kproc *
self(lua_State *L)
{
	return *(struct kproc **)lua_getextraspace(L);
}

/* procs live on the heap too. a dead one keeps its slot until the reaper
 * runs at the top of a lap, because dispatch reads its status right after
 * a resume that may have killed it -- freeing inside proc_kill would hand
 * dispatch a dangling pointer.
 */
struct kproc *procv[MAXPROCS];
int prochigh;

int nlive;

static int nextpid;

/* the machine-wide heap, where NCPU is 1. Null above that, and that is
 * the test for whether a proc owns the heap it points at. The
 * arrangement follows NCPU rather than platform_ncpu() -- see
 * docs/proc.md, which is worth reading before changing that.
 */
struct luaheap *shared_heap;

static unsigned int brokeseq;

/* how often the preempt hook samples the clock, in lua VM instructions.
 * The hook yields on elapsed time, so this is a sampling rate rather
 * than a slice length, and a proc overshoots its quantum by at most one
 * period. Measured at boot so the period stays a fixed fraction of the
 * quantum on any machine -- see docs/scheduling.md.
 */
int default_reductions = REDUCTIONS;

/* pooled bytes a proc may allocate between collector steps. Per proc
 * and unlocked, like every other counter here.
 */
#define GCDEBT	(64 * 1024)

struct kproc *
find_proc(int pid)
{
	for (int i = 0; i < MAXPROCS; i++)
		if (procv[i] && procv[i]->status != DEAD &&
		    procv[i]->id == pid)
			return procv[i];
	return 0;
}

/* remove the file half of io; the console half stays. see kernel.h on
 * why this is callable from linit.c as well as proc_new.
 */
void
kernel_strip_io(lua_State *L)
{
	static const char *const gone[] = {
		"open", "lines", "input", "output", "popen", "tmpfile", NULL
	};

	if (!lua_istable(L, -1))
		return;
	for (int i = 0; gone[i]; i++) {
		lua_pushnil(L);
		lua_setfield(L, -2, gone[i]);
	}
}

void
kernel_strip_debug(lua_State *L)
{
	static const char *const gone[] = {
		"sethook", "getupvalue", "setupvalue", "upvalueid",
		"upvaluejoin", "setlocal", "setmetatable", "getregistry",
		"getuservalue", "setuservalue", NULL
	};

	if (!lua_istable(L, -1))
		return;
	for (int i = 0; gone[i]; i++) {
		lua_pushnil(L);
		lua_setfield(L, -2, gone[i]);
	}
}

static int
confined_load(lua_State *L)
{
	if (lua_gettop(L) < 3)
		lua_settop(L, 3);	/* pad chunk, name, mode; keep env */
	lua_pushliteral(L, "t");
	lua_replace(L, 3);		/* text only, dropping any 'b' */

	int n = lua_gettop(L);

	lua_pushvalue(L, lua_upvalueindex(1));
	lua_insert(L, 1);
	lua_call(L, n, LUA_MULTRET);
	return lua_gettop(L);
}

/* wrap load() and drop string.dump in a non-boot proc. Same door as
 * loadfile/dofile, which proc_new removes outright: a chunk off the
 * disk and a chunk of bytecode are the one hole wearing two names.
 */
void
kernel_confine_load(lua_State *L)
{
	lua_getglobal(L, "load");
	if (lua_isfunction(L, -1)) {
		lua_pushcclosure(L, confined_load, 1);
		lua_setglobal(L, "load");
	} else {
		lua_pop(L, 1);
	}

	lua_getglobal(L, "string");
	if (lua_istable(L, -1)) {
		lua_pushnil(L);
		lua_setfield(L, -2, "dump");
	}
	lua_pop(L, 1);
}

/* Confine a non-boot proc. Called protected: lua_getglobal fires _G's
 * lazy loader, which allocates, and proc_new has no error handler -- a
 * failed allocation here aborts the machine, not the spawn.
 */
static int
confine_proc(lua_State *L)
{
	/* referencing "io" here also FORCES the lazy load, so the table
	 * exists and is stripped rather than being created fresh (and
	 * whole) at first use.
	 */
	lua_getglobal(L, "io");
	kernel_strip_io(L);
	lua_pop(L, 1);

	lua_getglobal(L, "debug");
	kernel_strip_debug(L);
	lua_pop(L, 1);

	/* loadfile/dofile off the disk, load "b" out of a string: one
	 * hole, three names. confine_load forces text and drops
	 * string.dump.
	 */
	lua_pushnil(L);
	lua_setglobal(L, "loadfile");
	lua_pushnil(L);
	lua_setglobal(L, "dofile");
	kernel_confine_load(L);
	return 0;
}

/* collectgarbage with the verb ignored: one full collect, never a
 * restart. The kernel owns the schedule (GCSTOP, gc_step); a restart
 * would let a finalizer run mid-allocation. GCCOLLECT keeps the stop.
 */
static int
confined_collectgarbage(lua_State *L)
{
	lua_gc(L, LUA_GCCOLLECT);
	lua_pushinteger(L, 0);	/* what collectgarbage("collect") returns */
	return 1;
}

void
kernel_confine_gc(lua_State *L)
{
	lua_pushcfunction(L, confined_collectgarbage);
	lua_setglobal(L, "collectgarbage");
}

int
kernel_current_is_boot(void)
{
	return cpu_self()->current &&
	    (cpu_self()->current->priv & PRIV_BOOT) != 0;
}

static int
kernel_cowrap_k(lua_State *L, int status, lua_KContext ctx)
{
	lua_State *co = lua_tothread(L, lua_upvalueindex(1));

	(void)status;
	(void)ctx;
	/* no arguments on the way back in: the coroutine is stopped
	 * mid-instruction, not waiting at a yield for a value.
	 */
	return kernel_cowrap_resume(L, co, 0);
}

int
kernel_cowrap_resume(lua_State *L, lua_State *co, int narg)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(co);

	for (;;) {
		int nres, st;

		if (!lua_checkstack(co, narg))
			return luaL_error(L, "too many arguments to resume");
		lua_xmove(L, co, narg);
		kx->preempted = 0;
		st = lua_resume(co, L, narg, &nres);
		if (st != LUA_OK && st != LUA_YIELD) {
			int s = lua_status(co);

			if (s != LUA_OK && s != LUA_YIELD) {
				s = lua_closethread(co, L);
				lua_xmove(co, L, 1);
			} else {
				lua_xmove(co, L, 1);
			}
			if (s != LUA_ERRMEM &&
			    lua_type(L, -1) == LUA_TSTRING) {
				luaL_where(L, 1);
				lua_insert(L, -2);
				lua_concat(L, 2);
			}
			return lua_error(L);
		}
		if (!lua_checkstack(L, nres + 1)) {
			lua_pop(co, nres);
			return luaL_error(L, "too many results to resume");
		}
		lua_xmove(co, L, nres);
		if (st != LUA_YIELD || !kx->preempted)
			return nres;

		/* stopped by the hook. Nothing was yielded -- drop it
		 * anyway rather than trust the count -- and go round.
		 */
		lua_pop(L, nres);
		kx->preempted = 0;
		if (!lua_isyieldable(L)) {
			/* nowhere to hand the quantum to, so carry on
			 * rather than report a generator that is not
			 * finished as finished. Correctness first; the
			 * proc is descheduled at the next chance.
			 */
			narg = 0;
			continue;
		}
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
		return lua_yieldk(L, 0, 0, kernel_cowrap_k);
	}
}

static int
kernel_cowrap_aux(lua_State *L)
{
	lua_State *co = lua_tothread(L, lua_upvalueindex(1));

	return kernel_cowrap_resume(L, co, lua_gettop(L));
}

static int
kernel_cowrap(lua_State *L)
{
	lua_State *co;

	luaL_checktype(L, 1, LUA_TFUNCTION);
	co = lua_newthread(L);
	lua_pushvalue(L, 1);
	lua_xmove(L, co, 1);
	lua_pushcclosure(L, kernel_cowrap_aux, 1);
	return 1;
}

void
kernel_wrap_coroutine(lua_State *L)
{
	if (!lua_istable(L, -1))
		return;
	lua_pushcfunction(L, kernel_cowrap);
	lua_setfield(L, -2, "wrap");
}

/* (re)size a proc's ring and make the mask match. n == 0 frees it.
 *
 * shared by sys.set_trace and spawn's opts.trace, so there is one place
 * that knows the flag has to be set BEFORE proc_rearm -- proc_hookmask
 * reads it, and proc_rearm is what makes the mask real on every
 * coroutine of the proc.
 */
int
trace_arm(struct kproc *p, int n)
{
	if (p->trace) {
		free(p->trace->ent);
		free(p->trace);
		p->trace = 0;
	}
	if (n > 0) {
		struct ktrace *t = malloc(sizeof *t);

		if (!t)
			return -1;
		memset(t, 0, sizeof *t);
		t->ent = malloc((size_t)n * sizeof *t->ent);
		if (!t->ent) {
			free(t);
			return -1;
		}
		t->cap = (unsigned int)n;
		t->lastid = -1;
		p->trace = t;
	}
	proc_rearm(p);
	return 0;
}

/* chunks for the lua heap, through the platform's pool. The machine
 * loses about a quarter again on top of every byte the heap believes it
 * mapped, and kheap_stats cannot see it, because the pool's metadata is
 * not ours.
 *
 * Taking whole pages instead looks like the obvious fix and measures
 * substantially worse, flat across chunk sizes: the pool reuses pages
 * it already holds better than we ask for new ones. Do not retry it
 * without measuring both.
 */
static const struct luaheap_ops kalloc_ops = {
	.chunk_alloc = kalloc_chunk,
	.chunk_free = kalloc_free_chunk,
};

static void *
kalloc_chunk(void *ud, size_t n)
{
	(void)ud;
	return platform_chunk_alloc(n);
}

static void
kalloc_free_chunk(void *ud, void *p, size_t n)
{
	(void)ud;
	platform_chunk_free(p, n);
}

/* ---- pooled bytes ----
 *
 * los.buf takes storage from the chunk source rather than a proc's lua
 * heap, so kalloc never sees it. It is charged here against the same
 * cap: a proc that can allocate outside its budget has no budget.
 * buf_used counts the same bytes again on their own, because memory
 * that is not in the numbers is memory nobody finds. Every counter
 * belongs to one proc, so nothing here needs a lock.
 */
int
kbuf_charge(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	if (p->mem_limit && p->mem_used + n > p->mem_limit)
		return 0;
	p->mem_used += n;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	p->buf_used += n;

	/* pace the collector by these bytes: a proc that only receives
	 * buffers holds megabytes of them while its lua heap looks idle.
	 * gc_step takes the step, at the dispatch point where nothing is
	 * held -- a step here would run a finalizer under a bucket.
	 */
	p->gc_owed += n;
	return 1;
}

void
kbuf_uncharge(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	p->mem_used -= n;
	p->buf_used -= n;
}

int
kbuf_step_due(lua_State *L, size_t n)
{
	struct kproc *p = self(L);

	p->buf_debt += n;
	if (p->buf_debt < GCDEBT)
		return 0;
	p->buf_debt = 0;
	return 1;
}

size_t
kbuf_pooled(void)
{
	size_t total = 0;

	for (int i = 0; i < prochigh; i++)
		if (procv[i])
			total += procv[i]->buf_used;
	return total;
}

/* lua allocator with per-proc accounting. note lua's convention: when
 * ptr is NULL, osize carries the object type, not a size. luaheap is
 * given a real size instead, and depends on it being one -- that is
 * what lets a block carry no header.
 */
static void *
kalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	struct kproc *p = ud;
	size_t real_osize = ptr ? osize : 0;

	if (nsize == 0) {
		luaheap_realloc(p->heap, ptr, real_osize, 0);
		p->mem_used -= real_osize;
		return 0;
	}
	/* enforce the limit only on growth so gc/shrink always succeeds.
	 * The limit is on what lua asked for, not on what the heap mapped
	 * to serve it, so a proc's budget means the same thing it did
	 * before this allocator existed.
	 */
	if (p->mem_limit && nsize > real_osize &&
	    p->mem_used - real_osize + nsize > p->mem_limit)
		return 0;

	void *q = luaheap_realloc(p->heap, ptr, real_osize, nsize);

	if (!q)
		return 0;
	p->mem_used += nsize - real_osize;
	if (p->mem_used > p->mem_peak)
		p->mem_peak = p->mem_used;
	/* growth only, and the test is what makes it so: gc_owed is
	 * unsigned, so adding a shrink wraps it to near SIZE_MAX.
	 */
	if (nsize > real_osize) {
		p->gc_owed += nsize - real_osize;
		p->gc_idle_owed += nsize - real_osize;
	}
	return q;
}

/* where a lua warning goes. Without one, lua drops them: lua_newstate
 * leaves warnf null and only luaL_newstate installs a default.
 *
 * The warning that matters here is an error inside a __gc handler. Lua
 * runs a finalizer protected and reports failure through this path
 * rather than raising, so with no warn function a finalizer that throws
 * is invisible -- no message, no counter, and the handle it was meant
 * to close stays open. A split message reads as two lines, since
 * joining them would need a buffer for a case that does not arise.
 */
static void
kernel_warn(void *ud, const char *msg, int tocont)
{
	struct kproc *p = ud;

	char b[256];

	(void)tocont;
	snprintf(b, sizeof b, "lua: %s: %s",
	    p && p->name[0] ? p->name : "?", msg);
	kernel_log(b);
}

/* one collector step, called through lua_pcall. The protection is not
 * decoration: a step allocates, and an allocation that cannot be served
 * raises. Reached from plain C that error finds no handler, and lua's
 * last resort is a panic function this state does not install, so it
 * aborts the machine for one proc that ran out of memory.
 */
static int
gc_step_k(lua_State *L)
{
	int kb = (int)lua_tointeger(L, lua_upvalueindex(1));

	if (kb == 0)
		lua_gc(L, LUA_GCCOLLECT);
	else
		lua_gc(L, LUA_GCSTEP, kb);
	return 0;
}

/* one collector call, protected: a step of kb kilobytes, or a whole
 * cycle where kb is 0. Errors are reported and swallowed -- the caller
 * is the scheduler, and a proc that cannot collect is not a machine
 * fault.
 */
static void
gc_protected(struct kproc *p, lua_State *L, size_t kb)
{
	/* lua turns this back into bytes as an l_mem, which is 32 bits wide
	 * on esp32. Too large a step overflows it to a negative debt, and
	 * the collector reads that as credit and does nothing.
	 */
	if (kb > GCSTEP_MAX_KB)
		kb = GCSTEP_MAX_KB;

	lua_pushinteger(L, (lua_Integer)kb);
	lua_pushcclosure(L, gc_step_k, 1);
	if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
		const char *e = lua_tostring(L, -1);
		char b[256];

		snprintf(b, sizeof b, "lua: %s: gc: %s", p->name,
		    e ? e : "?");
		kernel_log(b);
		lua_pop(L, 1);
	}
}

/* run the collector for one proc, at the one place it is allowed to.
 * The collector is stopped, so this is the only thing that advances it
 * and the only place a __gc handler can run. That is the point: such a
 * handler is arbitrary lua, and closing a handle is what they are for,
 * so it reaches port_unref on a port nobody named -- which needs every
 * bucket, and a caller holding one may not widen. Here nothing is held.
 * How often this runs is what paces it, not the size passed in: the
 * generational collector does one minor collection per call whatever
 * the debt says. The size still matters to an incremental one.
 */
void
gc_step(struct kproc *p, lua_State *L, int mark)
{
	size_t kb;

	if (!L || p->gc_owed < GCSTEP_MIN)
		return;
	if (!lua_checkstack(L, 3))
		return;

	kb = p->gc_owed / 1024;
	p->gc_owed = 0;

	/* From the count hook this falls between two line events, and is
	 * charged to the interrupted line -- the heaviest allocator, which
	 * raises gc_owed fastest. From dispatch it is inside <scheduled>.
	 */
	if (mark)
		trace_mark(p, "<gc>");

	gc_protected(p, L, kb);
}

/* collect a parked proc, which nothing else will: gc_step runs at a
 * dispatch point. kernel_run claims the proc as dispatch does. A whole
 * cycle rather than a step, because an object that dies during an
 * incremental cycle is swept by the next one -- so lua reporting a
 * cycle finished is not a report that nothing is left, and a parked
 * proc holds that remainder forever. Idle is what pays for the cycle. */
void
gc_idle_collect(struct kproc *p)
{
	if (!p->L)
		return;

	p->gc_owed = 0;
	p->gc_idle_owed = 0;
	gc_protected(p, p->L, 0);
}

/* tear down a proc's state.
 *
 * lua_close cannot be skipped even though the heap is about to be
 * destroyed whole: __gc finalizers are how handles get clunked, so
 * dropping the memory without running them would leak what the memory
 * was only pointing at. Destroying the heap afterwards is what returns
 * the chunks, which a shared heap could not do.
 */
static void
proc_freestate(struct kproc *p)
{
	if (p->L)
		lua_close(p->L);
	p->L = 0;
	p->co = 0;
	/* after lua_close, never before: the finalizers it runs are
	 * still allocating and freeing in this heap.
	 */
	if (p->heap && p->heap != shared_heap) {
		luaheap_destroy(p->heap);
	} else if (p->heap) {
		/* a shared heap keeps what this proc was using, because
		 * the chunks it sat in belong to the machine rather than
		 * to the proc. This is the one moment worth looking: a
		 * program that ran and exited has just dropped its whole
		 * working set, and the chunks it was carved from are
		 * empty now or never.
		 *
		 * Per-proc heaps need none of this -- destroy hands every
		 * chunk back at once.
		 */
		luaheap_reclaim(p->heap);
	}
	p->heap = 0;
	/* lua_close frees every coroutine through kernel_cofree, so the
	 * list is already empty; re-init rather than trust that, since a
	 * reused slot would inherit whatever is left
	 */
	TAILQ_INIT(&p->coros);
	p->hookforced = 0;
	/* the trace outlives the death and not the state: it is freed
	 * here, with the heap it describes, so a corpse still answers
	 * "how did it get there" for as long as it answers "where"
	 */
	if (p->trace) {
		free(p->trace->ent);
		free(p->trace);
		p->trace = 0;
	}
	/* the debug state names lua_States, so it dies with them. A
	 * corpse keeps both: proc_break does not come here.
	 */
	dbg_free(p);
}

/* lua's per-state creation and teardown hooks, from coreg.h.
 *
 * costart runs after lua has copied the new state's extra space, so the
 * kproc pointer is already right and only the links need setting.
 * cofree runs before the state's memory goes back, the last moment the
 * link is valid, and is reached for every coroutine. The main state is
 * created before the proc pointer exists, so it is not listed -- and
 * nothing needs to arm it, because the chunk runs in p->co.
 */
void
kernel_costart(lua_State *from, lua_State *nw)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(nw);
	struct kproc *p = ((struct kextra *)lua_getextraspace(from))->p;

	kx->p = p;
	kx->preempted = 0;
	memset(&kx->link, 0, sizeof kx->link);
	if (p && p->coros.tqh_last)
		TAILQ_INSERT_TAIL(&p->coros, kx, link);
}

void
kernel_cofree(lua_State *from, lua_State *dead)
{
	struct kextra *kx = (struct kextra *)lua_getextraspace(dead);

	(void)from;
	if (kx->p && kx->link.tqe_prev)
		TAILQ_REMOVE(&kx->p->coros, kx, link);
	memset(&kx->link, 0, sizeof kx->link);
}

/* the only place a hook mask is decided.
 *
 * LUA_MASKCOUNT is not conditional and must never become so: it is the
 * preemption budget, and a proc whose count hook went missing holds the
 * machine until it blocks. Tracing can only add LUA_MASKLINE to it, and
 * every lua_sethook here comes through this, so turning tracing off is
 * not a route to turning preemption off with it.
 */
static int
proc_hookmask(struct kproc *p)
{
	/* tracing and the debugger both want LUA_MASKLINE, which is why
	 * one place computes the mask: a second opinion would let one
	 * disarm the other, or disarm preemption.
	 */
	return LUA_MASKCOUNT
	    | ((p->trace || dbg_wants_lines(p->dbg)) ? LUA_MASKLINE : 0);
}

/* arm every coroutine of a proc at `count`.
 *
 * every one, not just p->co: lua_newthread copies the hook when it is
 * created and never looks again, so a mask or count set on one
 * coroutine reaches no other. the list is exact (src/coreg.h) rather
 * than inferred from reachability, which matters both for a coroutine
 * held only from a C closure's upvalue and for being able to do this
 * from inside the hook without allocating.
 */
void
proc_armall(struct kproc *p, int count)
{
	struct kextra *kx;

	if (!p->L || !p->co)
		return;
	TAILQ_FOREACH(kx, &p->coros, link)
		lua_sethook(kx_state(kx), preempt_hook, proc_hookmask(p),
		    count);
}

void
proc_rearm(struct kproc *p)
{
	proc_armall(p, p->reductions);
}

/* record one line. only ever called from a line event, where lua has
 * already filled ar->currentline -- asking lua_getinfo for it would be
 * paying twice for something the hook was handed.
 */
static void
trace_line(struct kproc *p, lua_State *L, lua_Debug *ar)
{
	struct ktrace *t = p->trace;
	int src = 0, co = 0;

	if (!t || !t->cap)
		return;

	/* "S" is push-free and call-free, the same reason src/debug.c
	 * asks for "Sln" and not "f" or "L": a hook that could run target
	 * code or allocate in the target would be changing the thing it
	 * is recording.
	 */
	if (lua_getinfo(L, "S", ar) && ar->source) {
		if (ar->source == t->lastsrc) {
			src = t->lastid;
		} else {
			for (src = 0; src < t->nname; src++)
				if (!strcmp(t->name[src], ar->short_src))
					break;
			if (src == t->nname) {
				if (t->nname >= TRACESRC)
					src = 0;	/* out of slots */
				else
					snprintf(t->name[t->nname++],
					    LUA_IDSIZE, "%s", ar->short_src);
			}
			t->lastsrc = ar->source;
			t->lastid = src;
		}
	}

	/* which coroutine, by identity only: the pointer names a thread
	 * for as long as this trace is worth reading and is never
	 * dereferenced. lib/thread procs interleave threads line by
	 * line, and a trace that could not tell them apart would read as
	 * one impossible execution.
	 */
	for (co = 0; co < t->nco; co++)
		if (t->co[co] == (const void *)L)
			break;
	if (co == t->nco) {
		if (t->nco >= TRACECO)
			co = 0;
		else
			t->co[t->nco++] = (const void *)L;
	}

	trace_put(p, t, ar->currentline, src, co);
}

/* One entry, with both clocks.
 *
 * A single platform_ticks() yields both: the wall reading directly, and
 * this proc's running cycles as cputime plus however long it has been
 * on the cpu since it was resumed. p->resumed exists for exactly this
 * -- its own comment says "for the hook" -- so nothing new has to be
 * tracked to get the second number.
 */
static void
trace_put(struct kproc *p, struct ktrace *t, int line, int src, int co)
{
	unsigned long long now = platform_ticks();
	unsigned long long cpu = p->cputime +
	    (p->resumed && now > p->resumed ? now - p->resumed : 0);
	struct tracent *e;

	/* The elapsed time belongs to the previous entry, not this one: a
	 * line hook fires before its line runs, so the interval between
	 * two hooks is the cost of the earlier line. Recording it against
	 * the arriving entry shifts the whole profile down by one, and
	 * names a line that is usually innocent and cheap.
	 *
	 * The newest entry carries zero until the next line arrives,
	 * which is honest: nothing has happened after it yet.
	 */
	if (t->n > 0) {
		struct tracent *prev = &t->ent[(t->n - 1) % t->cap];
		unsigned long long dw = now - t->lastwall;
		unsigned long long dc = cpu > t->lastcpu ? cpu - t->lastcpu : 0;

		/* saturate rather than wrap: a proc that was away for a
		 * second is worth seeing as "a very long time" and not as a
		 * small number.
		 */
		prev->wall = dw > 0xffffffffull ? 0xffffffffu :
		    (unsigned int)dw;
		prev->cpu = dc > 0xffffffffull ? 0xffffffffu :
		    (unsigned int)dc;
	}

	e = &t->ent[t->n % t->cap];
	e->line = line;
	e->src = (unsigned short)src;
	e->co = (unsigned short)co;
	e->wall = 0;
	e->cpu = 0;

	t->lastwall = now;
	t->lastcpu = cpu;
	t->n++;
}

/* A marker entry, for something that is not a line of lua. A context
 * switch is the one that matters: without it the gap appears as a huge
 * wall delta on whichever line ran last, and the reader has to guess
 * whether that line was slow or the proc was not running. With it the
 * histogram has somewhere honest to put those intervals.
 *
 * The name is interned in the same table as a source file, so it costs
 * one of TRACESRC's slots and reads as a filename with line 0.
 */
void
trace_mark(struct kproc *p, const char *what)
{
	struct ktrace *t = p ? p->trace : 0;
	int src;

	if (!t || !t->cap)
		return;

	for (src = 0; src < t->nname; src++)
		if (!strcmp(t->name[src], what))
			break;
	if (src == t->nname) {
		if (t->nname >= TRACESRC)
			return;		/* out of slots; a marker is not worth evicting a file */
		snprintf(t->name[t->nname++], LUA_IDSIZE, "%s", what);
	}

	/* the source cache names a lua string pointer, and this is not
	 * one -- clear it so the next real line re-interns rather than
	 * matching a marker's slot.
	 */
	t->lastsrc = 0;
	trace_put(p, t, 0, src, 0);
}

/* Leave the proc from wherever the hook fired. A yield reaches only
 * the resumer of its own state, so the trip out is forced one level
 * per instruction. Preemption and the debugger share it.
 */
static void
preempt_walkout(struct kproc *p, lua_State *L)
{
	if (p && L != p->co) {
		if (p->hookforced) {
			/* p->co is armed and still unreached, so the chain
			 * is deeper than one level: arm every coroutine
			 * and walk out one instruction per level.
			 */
			proc_armall(p, 1);
			p->hookforced = 2;
		} else {
			lua_sethook(p->co, preempt_hook, proc_hookmask(p),
			    1);
			p->hookforced = 1;
		}
	}
	/* the resumer never asked for this: kernel_cowrap reads the mark
	 * and resumes again, and src/thread.c handles the yield itself.
	 */
	if (p && L != p->co)
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
	lua_yield(L, 0);
}

/* the only preemption there is: no clock interrupt reaches a running
 * proc, so this fires every N lua instructions and yields once a
 * wall-clock quantum has passed. The instruction count is the sampling
 * rate, not the slice.
 *
 * It cannot fire inside a single C call, so string.rep("x", 1e8) holds
 * the machine for as long as it takes. Nothing here can fix that.
 */
static void
preempt_hook(lua_State *L, lua_Debug *ar)
{
	struct kproc *p = *(struct kproc **)lua_getextraspace(L);

	/* a line event is a trace event and nothing else. preemption
	 * stays entirely on the count event, so turning tracing on does
	 * not change when a proc yields -- the scheduling this hook
	 * exists for is the same whether or not anyone is watching.
	 */
	if (ar->event == LUA_HOOKLINE) {
		if (!p)
			return;
		if (p->trace)
			trace_line(p, L, ar);
		if (!p->dbg)
			return;
		dbg_line(p->dbg, L, ar);
		if (!atomic_load_explicit(&p->dbg->pending,
		    memory_order_relaxed))
			return;
		/* here, not at the next count event: a breakpoint leaves
		 * the state suspended at the line. A frame that cannot
		 * yield keeps pending set and stops later.
		 */
		if (lua_isyieldable(L))
			preempt_walkout(p, L);	/* does not return */
		return;
	}
	/* the forced trip below leaves states sampling every instruction.
	 * put them back the moment it has done its job, which is the
	 * first time the hook fires on p->co afterwards.
	 */
	if (p && L == p->co && p->hookforced) {
		if (p->hookforced == 2)
			proc_armall(p, p->reductions);
		else
			lua_sethook(p->co, preempt_hook, proc_hookmask(p),
			    p->reductions);
		p->hookforced = 0;
	}
	if (!lua_isyieldable(L))
		return;

	/* the second safe point, and the one that paces the collector.
	 * The dispatch point runs once a slice, and a proc can allocate
	 * megabytes inside one slice -- stepping harder there cannot
	 * help, because the garbage is made after the step.
	 * A count hook is a legal place: it fires between two vm
	 * instructions, so no kernel function is on the stack and no
	 * bucket is held, and lua bars a finalizer from recursing into
	 * this hook. After the yieldable test on purpose -- a legal yield
	 * here is the cheapest evidence this is not a boundary.
	 */
	if (p)
		gc_step(p, L, 1);

	/* torture: stop this thread between every pair of instructions.
	 * A race between a thread and thread.run is a window of one or
	 * two instructions, and whether a run lands in one depends on how
	 * finely the work gets cut, which is why this class of bug shows
	 * on slow hardware and not on fast.
	 * Threads only: the walk-out below is skipped, because a kernel
	 * round trip per instruction turns a ten second test into an
	 * afternoon. So a tortured proc does not honor its quantum while
	 * a thread runs, and is PRIV_BOOT only for that reason.
	 */
	if (p && p->torture && L != p->co) {
		((struct kextra *)lua_getextraspace(L))->preempted = 1;
		lua_yield(L, 0);
		return;		/* not reached */
	}

	/* a stop outranks the quantum: a swallowed one from this hook,
	 * or one the debugger asked for while the proc was running.
	 */
	int stopping = 0;

	if (p && p->dbg) {
		struct kdbg *d = p->dbg;

		if (atomic_load_explicit(&d->pending, memory_order_relaxed))
			stopping = 1;
		else if (atomic_load_explicit(&d->stopreq,
		    memory_order_relaxed)) {
			dbg_arm_stop(d, L, ar, DBG_REQ, 0);
			stopping = 1;
		}
	}

	if (!stopping && p && p->resumed && quantum_cycles &&
	    platform_ticks() - p->resumed < quantum_cycles)
		return;		/* under quantum: let it keep the cpu */

	/* A yield reaches only the resumer of the state the hook fired
	 * in. For a thread that is the proc's own scheduler, so yielding
	 * here hands the cpu back to thread.run and the proc keeps the
	 * machine -- a spinner in a thread starves everything else.
	 * Lua has no yield-across-levels, so the trip is forced: arm the
	 * proc's outermost state to fire on its next instruction, and the
	 * hook fires again with L == p->co, where a yield does reach the
	 * kernel. That also leaves the choice of what runs next with
	 * thread.run, where it belongs.
	 */
	preempt_walkout(p, L);
}

int
proc_new(const char *code, size_t codelen, const char *chunkname, int is_file,
    int reductions, size_t mem_limit, int port_limit, int priv)
{
	struct kproc *p = 0;

	for (int i = 0; i < MAXPROCS; i++)
		if (!procv[i] || procv[i]->status == DEAD) {
			if (!procv[i]) {
				procv[i] = malloc(sizeof *procv[i]);
				if (!procv[i])
					return -1;
				memset(procv[i], 0, sizeof *procv[i]);
			}
			p = procv[i];
			/* a reused slot still holds the last occupant's
			 * fields; only the id must survive nothing, so wipe
			 * it rather than trusting every assignment below to
			 * cover every field
			 */
			memset(p, 0, sizeof *p);
			if (i >= prochigh)
				prochigh = i + 1;
			break;
		}
	if (!p)
		return -1;

	memset(p->rights, 0, sizeof p->rights);
	p->nwatch = 0;
	p->reductions = reductions > 0 ? reductions : default_reductions;
	p->mem_used = 0;
	p->buf_used = 0;
	p->mem_peak = 0;
	/* the limit goes live only after setup: base state + libraries
	 * are counted but never refused, so a tiny limit can't panic
	 * openlibs. the chunk's first over-limit allocation then fails
	 * inside the protected resume (clean LUA_ERRMEM death).
	 */
	p->mem_limit = 0;
	/* before any lua_State exists: kernel_costart consults this to
	 * decide whether the proc is ready to own coroutines
	 */
	TAILQ_INIT(&p->coros);
	p->hookforced = 0;
	/* No placement: there is one run queue for the machine, so
	 * whichever cpu looks next runs this proc, and takes it again
	 * whenever it is next runnable.
	 *
	 * p->home records where it last ran, set by run_proc -- plan 9's
	 * affinity rather than a placement. Nothing decides anything from
	 * it today; it answers "which cpu is this on" for the smp tests,
	 * and soft affinity would be a use of exactly this field.
	 */
	p->home = 0;

	/* before lua_newstate, which allocates through kalloc, which
	 * reaches this proc's heap -- and, where there is one cpu, every
	 * other proc's too. See the comment at shared_heap.
	 */
	if (NCPU > 1) {
		p->heap = luaheap_new(&kalloc_ops, 0);
	} else {
		if (!shared_heap)
			shared_heap = luaheap_new(&kalloc_ops, 0);
		p->heap = shared_heap;
	}
	if (!p->heap)
		return -1;
	p->L = lua_newstate(kalloc, p);
	if (!p->L)
		return -1;
	/* how far the heap may grow past what is live before the next
	 * cycle. Lua's 200 means it doubles, which on a board with a few
	 * hundred KB is most of the machine spent on garbage that has
	 * already been collected once.
	 *
	 * Incremental rather than the default generational, and gc_step
	 * depends on it: genstep does one minor collection per call and
	 * ignores the step size it is given, where incstep loops until the
	 * debt is paid and so honors it.
	 */
	lua_gc(p->L, LUA_GCINC, GCPAUSE, 0, 0);

	lua_setwarnf(p->L, kernel_warn, p);

	/* the collector runs where this kernel says and nowhere else.
	 * Left alone, lua collects inside an allocation, which puts an
	 * arbitrary __gc handler in the middle of whatever was
	 * allocating -- and closing a handle is what those handlers are
	 * for, so it reaches port_unref on a port that code never named.
	 * Stopping it makes that impossible rather than avoided.
	 * Two collections still happen unasked, and both are wanted: an
	 * emergency one on allocation failure, and lua_close running
	 * pending finalizers, which closes a dying proc's handles.
	 */
	lua_gc(p->L, LUA_GCSTOP);

	/* where self() finds the proc, set before any thread exists so
	 * lua_newthread copies it in. The whole record, not just the
	 * pointer: the links are copied from here too, so they must start
	 * empty.
	 */
	memset(lua_getextraspace(p->L), 0, LUA_EXTRASPACE);
	((struct kextra *)lua_getextraspace(p->L))->p = p;
	p->id = nextpid++;	/* unique forever; slots recycle, pids don't */
	{
		/* lua chunknames conventionally lead with '=' (shown as-is)
		 * or '@' (a file); strip that marker for display purposes.
		 */
		const char *nm = chunkname;

		if (nm && (*nm == '=' || *nm == '@'))
			nm++;
		snprintf(p->name, sizeof p->name, "%s", nm ? nm : "?");
	}
	luaL_openlibs(p->L);

	/* before the chunk has run, so what sys.log formats with is the
	 * real one whatever the proc does to string.format later.
	 */
	lua_getglobal(p->L, "string");
	lua_getfield(p->L, -1, "format");
	lua_rawsetp(p->L, LUA_REGISTRYINDEX, &fmtkey);
	lua_pop(p->L, 1);

	/* self port = right handle 0 */
	struct kport *port = port_new();

	if (!port || right_new(p, port, 1) != 0) {
		if (port)
			port->used = 0;	/* no rights were taken */
		proc_freestate(p);
		return -1;
	}
	p->selfidx = port->idx;
	p->selfgen = port->gen;

	/* register the los.* modules in package.preload so chunks pull in
	 * the layers they need with an explicit require -- no globals, no
	 * disk search. los.sys and los.efi are C openers; los.thread is the
	 * lua runtime, loaded from disk once and preloaded (not auto-run).
	 */
	lua_getglobal(p->L, "package");
	lua_getfield(p->L, -1, "preload");

	lua_pushcfunction(p->L, los_sys_open);
	lua_setfield(p->L, -2, "los.sys");

	lua_pushcfunction(p->L, luaopen_los_efi);
	lua_setfield(p->L, -2, "los.efi");

	/* ambient to require and gated per call: every function names a
	 * target and checks a right to it, so the module is not authority.
	 */
	lua_pushcfunction(p->L, luaopen_los_dbg);
	lua_setfield(p->L, -2, "los.dbg");

	/* crypto.native: chacha20, poly1305, sha-256, sha-512, aes.
	 * Ambient, unlike everything below it: authority is an argument
	 * here rather than the function, since it computes on a key the
	 * caller supplies and does nothing for a caller without one.
	 * Contrast los.platform.rng, where the raw draw is the capability.
	 * The C file is a verbatim copy from the ssh tree, where it is
	 * developed and where the RFC vectors run against both the C and
	 * the lua implementations. Keep it identical so the sync stays a
	 * copy and the check stays a diff.
	 */
	lua_pushcfunction(p->L, luaopen_ssh_crypto_native);
	lua_setfield(p->L, -2, "crypto.native");

	/* gefs.native (src/gefs_native.c): metrohash64, which lib/gefs
	 * checksums every block with. Ambient for the same reason as the
	 * two around it -- a pure function of the string handed to it,
	 * reaching nothing -- and lib/gefs/hash.lua picks it up on its own
	 * if it is there, falling back to its own Lua otherwise.
	 */
	lua_pushcfunction(p->L, luaopen_gefs_native);
	lua_setfield(p->L, -2, "gefs.native");

	/* los.inet (src/inet.c), ambient for the same reason as the one
	 * above: the internet checksum is arithmetic on a string the
	 * caller already has, and it reaches nothing. Withholding it would
	 * not withhold anything -- lib/ip4.lua keeps the same function in
	 * Lua and falls back to it, more slowly, with the same answer.
	 */
	lua_pushcfunction(p->L, luaopen_los_inet);
	lua_setfield(p->L, -2, "los.inet");

	/* los.ninep (src/ninep.c), ambient on the same argument: the 9P
	 * field layout is fixed by the protocol and reaches nothing.
	 * lib/ninep.lua keeps the whole codec in Lua as ninep.pure and
	 * answers the same, more slowly.
	 */
	lua_pushcfunction(p->L, luaopen_los_ninep);
	lua_setfield(p->L, -2, "los.ninep");

	/* los.crc (src/crc.c), ambient on the same argument: two check
	 * polynomials over a string the caller already has, reaching
	 * nothing. lib/zmodem.lua has both in Lua and falls back to them.
	 */
	lua_pushcfunction(p->L, luaopen_los_crc);
	lua_setfield(p->L, -2, "los.crc");

	/* los.rom: the embedded set as data, ambient for the same reason.
	 * require() already reads these bytes in every proc through
	 * luaL_loadfile -- below the lua-level io stripping -- so what
	 * this adds is the ability to list them, and to read one without
	 * executing it. That is what lets a namespace be mounted
	 * read-only over the image with no server behind it, which is the
	 * only way an unprivileged proc on this platform can find a
	 * program at all.
	 */
	lua_pushcfunction(p->L, luaopen_los_rom);
	lua_setfield(p->L, -2, "los.rom");

	/* los.font (src/font.c), ambient on the same argument as the three
	 * above: glyphs are data, not a device. render() rasterises a
	 * string the caller already has into a pixel rectangle and reaches
	 * nothing -- the authority to put those pixels on a screen is
	 * los.platform.fb, which is the owned capability. A framebuffer
	 * console (lib/fbcons.lua) is one renderer plus that one right.
	 */
	lua_pushcfunction(p->L, luaopen_los_font);
	lua_setfield(p->L, -2, "los.font");
	/* los.buf (src/buf.c): memory, not authority. A buffer is bytes a
	 * proc allocates from its own budget, so it is ambient for the
	 * same reason los.font is -- what it can reach is nothing it did
	 * not make.
	 */
	lua_pushcfunction(p->L, luaopen_los_buf);
	lua_setfield(p->L, -2, "los.buf");
	/* los.fs is the whole of raw ESP access -- enumeration, metadata
	 * and file data. it is registered for exactly two procs: the esp
	 * server task, which serves the disk to everyone else over a port
	 * (lib/espsrv.lua), and proc 0, which has to read the esp to
	 * bootstrap before that mount exists. every other proc reaches
	 * files through a mount, which is a right rather than a reference.
	 */
	if (priv & (PRIV_ESP | PRIV_BOOT)) {
		lua_pushcfunction(p->L, luaopen_los_fs);
		lua_setfield(p->L, -2, "los.fs");
	}

	/* los.platform.{cons,wire,power} are each registered ONLY for
	 * their one owning task -- not gated by a runtime check, simply
	 * absent from package.preload everywhere else, so there is no
	 * check to get wrong: the function isn't reachable to call.
	 */
	if (priv & PRIV_CONS) {
		lua_pushcfunction(p->L, luaopen_los_platform_cons);
		lua_setfield(p->L, -2, "los.platform.cons");
	}
	if (priv & PRIV_WIRE) {
		lua_pushcfunction(p->L, luaopen_los_platform_wire);
		lua_setfield(p->L, -2, "los.platform.wire");
	}
	if (priv & PRIV_POWER) {
		lua_pushcfunction(p->L, luaopen_los_platform_power);
		lua_setfield(p->L, -2, "los.platform.power");
	}
	if (priv & PRIV_P9) {
		lua_pushcfunction(p->L, luaopen_los_platform_p9);
		lua_setfield(p->L, -2, "los.platform.p9");
	}
	if (priv & PRIV_ETH) {
		lua_pushcfunction(p->L, luaopen_los_platform_eth);
		lua_setfield(p->L, -2, "los.platform.eth");
		/* the radio is one device: whoever moves its frames is
		 * whoever joins networks with it, as plan 9's ether is
		 * both. A no-op table on a platform whose NIC has nothing
		 * to associate with.
		 */
		lua_pushcfunction(p->L, luaopen_los_platform_wifi);
		lua_setfield(p->L, -2, "los.platform.wifi");
	}
	if (priv & PRIV_HCI) {
		lua_pushcfunction(p->L, luaopen_los_platform_hci);
		lua_setfield(p->L, -2, "los.platform.hci");
	}
	if (priv & PRIV_BLK) {
		lua_pushcfunction(p->L, luaopen_los_platform_blk);
		lua_setfield(p->L, -2, "los.platform.blk");
	}
	if (priv & PRIV_FLASH) {
		lua_pushcfunction(p->L, luaopen_los_platform_flash);
		lua_setfield(p->L, -2, "los.platform.flash");
	}
	if (priv & PRIV_FB) {
		lua_pushcfunction(p->L, luaopen_los_platform_fb);
		lua_setfield(p->L, -2, "los.platform.fb");
	}

	lua_pushcfunction(p->L, luaopen_los_thread);
	lua_setfield(p->L, -2, "los.thread");

	lua_pop(p->L, 2);	/* preload, package */

	/* ninep (lib/ninep.lua) is found via plain require("ninep") --
	 * LUA_PATH search, ordinary fopen() -- same as any other module.
	 * it used to need a preload workaround here because reading was
	 * disk-gated; now that read is ambient (see stdio.c's fopen),
	 * that workaround is gone and require() just works.
	 */

	/* every proc but proc 0 loses the file half of io, and loadfile
	 * and dofile with it. lib/nsio.lua puts io.open back over the
	 * proc's namespace, so a proc reaches exactly what was mounted for
	 * it and a proc given none cannot open a file at all.
	 *
	 * Removing the reference is the mechanism, not a check inside it:
	 * a function that is not there cannot be called wrong. The console
	 * half stays. Proc 0 keeps everything, because it builds the root
	 * namespace and has none to be confined to until it has.
	 */
	if (!(priv & PRIV_BOOT)) {
		lua_pushcfunction(p->L, confine_proc);
		if (lua_pcall(p->L, 0, 0, 0) != LUA_OK) {
			kputs("proc confine error: ");
			kputs(lua_tostring(p->L, -1));
			kputs("\n");
			lua_pop(p->L, 1);
			right_drop(p, &p->rights[0]);
			proc_freestate(p);
			return -1;
		}
	}

	/* every proc, boot included: lua does not schedule the collector. */
	kernel_confine_gc(p->L);

	p->co = lua_newthread(p->L);
	luaL_ref(p->L, LUA_REGISTRYINDEX);	/* anchor the thread */

	int rc;

	if (is_file)
		rc = luaL_loadfile(p->co, code);
	else
		rc = luaL_loadbuffer(p->co, code, codelen, chunkname);
	if (rc != LUA_OK) {
		kputs("proc load error: ");
		kputs(lua_tostring(p->co, -1));
		kputs("\n");
		right_drop(p, &p->rights[0]);
		proc_freestate(p);
		return -1;
	}

	/* the lua runtime (los.thread) is a preloaded module now, pulled in
	 * on demand by require("los.thread") -- no auto-run bootstrap.
	 */
	lua_sethook(p->co, preempt_hook, proc_hookmask(p), p->reductions);
	p->priv = priv;
	p->mem_limit = mem_limit;
	p->port_limit = port_limit;
	p->weight = 1;
	p->cputime = 0;
	p->cpu = 0;
	p->pri = 0;
	p->resumed = 0;
	p->lastupdate = uptime_ms();
	p->lastcpu = 0;
	p->exitcode = 0;
	p->exitmsg[0] = 0;
	SLIST_INIT(&p->waiters);
	p->onq = 0;
	p->pri = 0;

	/* born hatching: a proc runs only once its creator launches it.
	 *
	 * The caller still has to finish building it -- the spawn arg and
	 * nargs, a driver's device right, the boot proc's grants. A
	 * second cpu that dispatches it inside that window resumes a
	 * half-built proc and races the creator for its stack.
	 */
	p->status = HATCHING;
	nlive++;
	return p->id;
}

/* let a built proc run. Separate from proc_new because every caller has
 * setup to do first; one that forgets this leaves a proc blocked with
 * nothing able to wake it.
 */
void
proc_launch(struct kproc *p)
{
	make_ready(p);		/* caller holds an ipc bucket */
}

/* caller holds ipclock: proc_detach has it, the noproc path takes it.
 * locking here as well hangs any teardown with a watcher attached.
 */
void
notify_exit(struct kproc *watcher, int pid, const char *reason, int status,
    const char *exitmsg, int broke, int priv)
{
	/* `reason` and `exitmsg` are the dying proc's own text, the only
	 * part of this notice that is its data rather than the fact of its
	 * death, so they go only to a watcher that held a right to it when
	 * it asked. That a proc exited stays ambient: a child watching the
	 * parent that spawned it holds no right to that parent and must
	 * not need one. An emptied reason still reads as an abnormal exit,
	 * so a watcher learns its peer died badly without learning what it
	 * said. priv is 1 for a synthetic notice, where the reason is our
	 * answer rather than anything a proc said.
	 */
	if (!priv) {
		reason = reason ? "" : 0;
		exitmsg = 0;
	}

	struct wbuf w = { 0 };
	unsigned int npairs = 3;
	lua_Integer id = pid;
	lua_Integer st = status;

	if (reason)
		npairs++;
	if (exitmsg && exitmsg[0])
		npairs++;
	if (broke)
		npairs++;

	if (wbyte(&w, 'B') || wput(&w, &npairs, 4))
		goto fail;

	unsigned int klen = 4;

	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "exit", 4) ||
	    wbyte(&w, 'I') || wput(&w, &id, sizeof id))
		goto fail;

	klen = 6;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "normal", 6) ||
	    wbyte(&w, reason ? 'F' : 'T'))
		goto fail;

	klen = 6;
	if (wbyte(&w, 'S') || wput(&w, &klen, 4) || wput(&w, "status", 6) ||
	    wbyte(&w, 'I') || wput(&w, &st, sizeof st))
		goto fail;

	if (exitmsg && exitmsg[0]) {
		unsigned int mlen = strlen(exitmsg);

		klen = 7;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "exitmsg", 7) || wbyte(&w, 'S') ||
		    wput(&w, &mlen, 4) || wput(&w, exitmsg, mlen))
			goto fail;
	}

	if (reason) {
		unsigned int rlen = strlen(reason);

		if (rlen > 200)
			rlen = 200;
		klen = 6;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "reason", 6) || wbyte(&w, 'S') ||
		    wput(&w, &rlen, 4) || wput(&w, reason, rlen))
			goto fail;
	}
	if (broke) {
		klen = 5;
		if (wbyte(&w, 'S') || wput(&w, &klen, 4) ||
		    wput(&w, "broke", 5) || wbyte(&w, 'T'))
			goto fail;
	}
	/* no rights in an exit notice, so a refusal means only that the
	 * buffer comes back here to be freed.
	 */
	if (port_push_owned(watcher->rights[0].port, w.p, w.len, 0, 0, 0, 0))
		free(w.p);
	return;
fail:
	free(w.p);
}

/* everything dying does except freeing the state.
 *
 * The split exists for BROKE: a corpse stops being part of the machine
 * the instant it dies -- off the run queue, holding no rights, monitors
 * told -- and only then lingers. Deferring any of that to the reaper
 * makes a corpse a hazard: a parent would block in sys.monitor forever,
 * and a broke fileserver would wedge every client.
 * Only lua_close is deferred, so a __gc finalizer runs after its rights
 * are gone. They tolerate it, and one that fails is swallowed.
 */
static void
proc_detach(struct kproc *p, const char *why, const char *reason, int broke)
{
	wait_clear(p);
	proc_unqueue(p);
	nlive--;

	/* release every right this proc held; ports lose refs, orphaned
	 * queues flush, unreferenced ports free
	 */
	for (int i = 0; i < MAXRIGHTS; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used)
			right_drop(p, r);
	}
	free(p->xrights);
	p->xrights = 0;

	/* free the named-grant list. the rights it named were dropped in the
	 * loop above -- a grant is a right plus a name -- so only the list
	 * nodes remain to release.
	 */
	while (!SLIST_EMPTY(&p->grants)) {
		struct grant *g = SLIST_FIRST(&p->grants);

		SLIST_REMOVE_HEAD(&p->grants, e);
		free(g);
	}

	/* erlang-style DOWN: tell the watchers */
	for (int i = 0; i < p->nwatch; i++) {
		struct kproc *w = find_proc(p->watchers[i]);

		if (w)
			notify_exit(w, p->id, why ? reason : 0,
			    why ? -1 : p->exitcode,
			    why ? 0 : p->exitmsg, broke, p->wpriv[i]);
	}
	p->nwatch = 0;

	/* a debugger holds no monitor, so it is told here -- both deaths
	 * reach this, under the wide lock port_push wants.
	 */
	if (p->dbg)
		dbg_notify(p, DBG_RUN, 1);
}

/* The reason points into the lua state, which one path closes now and
 * the other later, so it is copied either way. No reason means it left
 * of its own accord, and that is logged too: a proc that exits while
 * starting looks exactly like one that never started. */
static void
proc_logdeath(struct kproc *p, const char *why, char *reason, size_t n)
{
	char buf[256];

	if (!why) {
		reason[0] = '\0';
		snprintf(buf, sizeof buf, "proc %d (%s) exited", p->id,
		    p->name);
		kernel_log(buf);
		return;
	}
	snprintf(reason, n, "%s", why);
	snprintf(buf, sizeof buf, "proc %d (%s) died: %s", p->id, p->name,
	    reason);
	kernel_log(buf);
}

void
proc_kill(struct kproc *p, const char *why)
{
	char reason[224];

	proc_logdeath(p, why, reason, sizeof reason);

	/* the lock goes around proc_detach and not around
	 * proc_freestate, which calls lua_close, which runs this proc's
	 * __gc finalizers -- arbitrary lua, and the reason those
	 * finalizers exist is to clunk handles, so they reach api_close
	 * and would take this lock while we held it.
	 */
	proc_freestate(p);

	ipclock_enter();
	proc_detach(p, why, reason, 0);
	p->status = DEAD;
	ipclock_leave();
}

void
proc_reap(struct kproc *p)
{
	if (p->status != BROKE)
		return;
	proc_freestate(p);
	p->status = DEAD;
}

void
proc_break(struct kproc *p, const char *why)
{
	char reason[224];
	struct kproc *oldest = 0;
	int n = 0;

	proc_logdeath(p, why, reason, sizeof reason);

	ipclock_enter();
	proc_detach(p, why, reason, 1);
	p->status = BROKE;
	p->brokeseq = ++brokeseq;

	for (int i = 0; i < prochigh; i++) {
		struct kproc *q = procv[i];

		if (!q || q->status != BROKE)
			continue;
		n++;
		if (!oldest || q->brokeseq < oldest->brokeseq)
			oldest = q;
	}
	ipclock_leave();
	/* outside: proc_reap frees the corpse's state, which is
	 * lua_close again and the same finalizer problem.
	 */
	if (n > MAXBROKE && oldest)
		proc_reap(oldest);
}


size_t
proc_heaps_release(void)
{
	size_t freed = 0;

	if (shared_heap)
		return luaheap_release(shared_heap);
	for (int i = 0; i < prochigh; i++)
		if (procv[i] && procv[i]->heap)
			freed += luaheap_release(procv[i]->heap);
	return freed;
}
