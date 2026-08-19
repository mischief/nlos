/* los.thread: the cooperative runtime, over los.sys.
 *
 * procs are isolated lua states and cross by port; threads are
 * coroutines inside one state. Channel and alt follow plan 9 libthread.
 */

#include <stddef.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

int luaopen_los_thread(lua_State *L);

/* Park record slots. Integer keys keep the record in a table's array
 * part, and its shape never changes, so it stays off the rehash path.
 */
enum {
	PR_PORT = 1,	/* port handle, or false */
	PR_PORTS,	/* table of handles, or false */
	PR_CHAN,	/* channel, or false */
	PR_RECV,	/* true when this park is a plain recv */
	PR_MAIL,	/* a handed-over message */
	PR_HASMAIL,	/* true; separate, since nil is a legal message */
	PR_SEND,	/* bytes of room wanted, or false */
	PR_N = PR_SEND,
};

/* Resume points for the calls that yield. */
enum {
	/* both are sys.alt; what differs is what this does with the
	 * answer. A set of plain receives has every wake accounted for,
	 * so nothing has to wake everyone to go looking.
	 */
	K_ALTMSG = 1,
	K_ALTANY,
	K_PARK,
	K_YIELD,
};

/* alt_k reads its context as a count of channel marks, so the one case
 * that is not a count needs a value no count can reach.
 */
#define K_ALTBARE	((lua_KContext)0x7fff0000)

/* Scheduler state for one proc.
 *
 * The ring indices and counters are C. Everything holding a lua value
 * stays in a lua table, reached by registry ref: the collector has to
 * see a parked thread's coroutine and its pending message.
 */
struct sched {
	int	runq;		/* array, ring between qhead and qtail */
	int	parked;		/* co -> park record */
	int	wake;		/* co -> true, staged by threads */
	int	woken;		/* co -> true, wake that beat the park */
	int	nonrecv;	/* co -> true, park that is not a recv */
	int	portq;		/* port -> co, or a list of co */
	int	pending;	/* port -> messages taken with no taker */
	int	parkrec;	/* co -> record, weak keys */
	int	altset;		/* port set for alt */
	int	altseen;	/* port -> generation, for dedup */
	int	altscratch;	/* co -> alt scratch, weak keys */
	int	current;	/* the running coroutine, or nil */
	int	inplace;	/* coroutine cut by the count hook */

	/* los.sys entry points, kept by ref rather than looked up */
	int	anyready, altpoll, alt, hungup, block, tryrecv;
	int	sendblock, close, send, timer, newport, sendright, call;
	int	replyports;	/* co -> {h,s}, weak keys */
	int	selfsend;	/* the proc own send right, or nil */

	lua_Integer selfport;	/* sys.SELF, read once */

	int	qhead, qtail;
	int	nthreads;
	int	altn, altnsend;
	unsigned altgen;
};

static struct sched *
getsched(lua_State *L)
{
	return (struct sched *)lua_touserdata(L, lua_upvalueindex(1));
}

/* Push one of our own entry points, carrying the shared upvalue.
 * lua_pushcfunction would make a closure with none, and getsched would
 * read past the end of it.
 */
static void
pushself(lua_State *L, lua_CFunction fn)
{
	lua_pushvalue(L, lua_upvalueindex(1));
	lua_pushcclosure(L, fn, 1);
}

static void
pushref(lua_State *L, int ref)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
}

/* t[k] = v, k at `ki`, v on top. Pops v. */
static void
setkey(lua_State *L, int ref, int ki)
{
	ki = lua_absindex(L, ki);
	pushref(L, ref);
	lua_pushvalue(L, ki);
	lua_pushvalue(L, -3);
	lua_rawset(L, -3);
	lua_pop(L, 2);
}

static void
clearkey(lua_State *L, int ref, int ki)
{
	ki = lua_absindex(L, ki);
	pushref(L, ref);
	lua_pushvalue(L, ki);
	lua_pushnil(L);
	lua_rawset(L, -3);
	lua_pop(L, 1);
}

/* Is t[k] set? k at `ki`. Leaves the stack as found. */
static int
haskey(lua_State *L, int ref, int ki)
{
	int got;

	ki = lua_absindex(L, ki);
	pushref(L, ref);
	lua_pushvalue(L, ki);
	lua_rawget(L, -2);
	got = !lua_isnil(L, -1);
	lua_pop(L, 2);
	return got;
}

/* Push t[k], k at `ki`. */
static void
getkey(lua_State *L, int ref, int ki)
{
	ki = lua_absindex(L, ki);
	pushref(L, ref);
	lua_pushvalue(L, ki);
	lua_rawget(L, -2);
	lua_remove(L, -2);
}

/* Push the park record for the coroutine at `ci`, making one if it has
 * none. The record is reused for the life of that coroutine.
 */
static void
pushrec(lua_State *L, struct sched *s, int ci)
{
	int i;

	getkey(L, s->parkrec, ci);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_createtable(L, PR_N, 0);
	for (i = 1; i <= PR_N; i++) {
		lua_pushboolean(L, 0);
		lua_rawseti(L, -2, i);
	}
	lua_pushvalue(L, -1);
	setkey(L, s->parkrec, ci);
}

/* Append the coroutine at `ci` to the run ring.
 *
 * Only the scheduler pushes. A thread stages a wake instead, which is
 * one store with no index that can go stale.
 */
static void
push(lua_State *L, struct sched *s, int ci)
{
	ci = lua_absindex(L, ci);
	s->qtail++;
	pushref(L, s->runq);
	lua_pushvalue(L, ci);
	lua_rawseti(L, -2, s->qtail);
	lua_pop(L, 1);
}

/* Take the next coroutine off the ring and push it. Returns 0 and
 * pushes nil when empty. The pair resets on drain, so it never grows.
 */
static int
pop(lua_State *L, struct sched *s)
{
	if (s->qhead > s->qtail) {
		lua_pushnil(L);
		return 0;
	}
	pushref(L, s->runq);
	lua_rawgeti(L, -1, s->qhead);
	lua_pushnil(L);
	lua_rawseti(L, -3, s->qhead);
	if (s->qhead == s->qtail) {
		s->qhead = 1;
		s->qtail = 0;
	} else {
		s->qhead++;
	}
	lua_remove(L, -2);
	return 1;
}

/* Ready the coroutine at `ci`.
 *
 * A wake for a thread that is not parked leaves a token instead.
 * Registering on a queue and parking are two steps, so a wake in that
 * gap would otherwise be slept through and both threads would park.
 */
static void
ready(lua_State *L, struct sched *s, int ci)
{
	ci = lua_absindex(L, ci);
	clearkey(L, s->nonrecv, ci);
	if (haskey(L, s->parked, ci)) {
		clearkey(L, s->parked, ci);
	} else {
		lua_pushboolean(L, 1);
		setkey(L, s->woken, ci);
	}
	lua_pushboolean(L, 1);
	setkey(L, s->wake, ci);
}

/* Hand `msg` at `mi`, taken from port `h`, to the coroutine at `ci`.
 * Returns 0 if that thread was readied for some other reason, which is
 * how stale queue entries are dropped.
 */
static int
handover(lua_State *L, struct sched *s, int ci, lua_Integer h, int mi)
{
	int ok;

	ci = lua_absindex(L, ci);
	mi = lua_absindex(L, mi);
	getkey(L, s->parked, ci);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return 0;
	}
	lua_rawgeti(L, -1, PR_RECV);
	ok = lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (ok) {
		lua_rawgeti(L, -1, PR_PORT);
		ok = lua_isnumber(L, -1) && lua_tointeger(L, -1) == h;
		lua_pop(L, 1);
	}
	if (!ok) {
		lua_pop(L, 1);
		return 0;
	}
	lua_pushvalue(L, mi);
	lua_rawseti(L, -2, PR_MAIL);
	lua_pushboolean(L, 1);
	lua_rawseti(L, -2, PR_HASMAIL);
	lua_pop(L, 1);
	ready(L, s, ci);
	return 1;
}

/* Give a message taken from port `h` to whoever is in recv() on it.
 * Returns 0 if nobody was waiting after all.
 */
static int
deliver(lua_State *L, struct sched *s, lua_Integer h, int mi)
{
	int done = 0;

	mi = lua_absindex(L, mi);
	pushref(L, s->portq);
	lua_pushinteger(L, h);
	lua_rawget(L, -2);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 2);
		return 0;
	}
	if (lua_type(L, -1) == LUA_TTHREAD) {
		lua_pushinteger(L, h);
		lua_pushnil(L);
		lua_rawset(L, -4);
		done = handover(L, s, -1, h, mi);
		lua_pop(L, 2);
		return done;
	}
	/* a list: drop stale entries as they are found */
	while (lua_rawlen(L, -1) > 0) {
		lua_rawgeti(L, -1, 1);
		/* shift the list down one */
		{
			lua_Integer n = (lua_Integer)lua_rawlen(L, -2), i;

			for (i = 1; i < n; i++) {
				lua_rawgeti(L, -2, i + 1);
				lua_rawseti(L, -3, i);
			}
			lua_pushnil(L);
			lua_rawseti(L, -3, n);
		}
		done = handover(L, s, -1, h, mi);
		lua_pop(L, 1);
		if (done)
			break;
	}
	lua_pop(L, 2);
	return done;
}

/* Refill the port set handed to alt. Returns its length.
 *
 * Filled in place rather than rebuilt. Both tails are cleared: a
 * receive landing where a send wait was would otherwise leave a stale
 * size and the kernel would wait for room nobody wants.
 */
/* fill case n of the set. The case tables are reused across parks, so a
 * park that waits on the same ports twice allocates nothing.
 */
static void
altcase(lua_State *L, int set, int n, lua_Integer h, lua_Integer need, int hup)
{
	int c;

	lua_rawgeti(L, set, n);
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		lua_createtable(L, 0, 3);
		lua_pushvalue(L, -1);
		lua_rawseti(L, set, n);
	}
	c = lua_gettop(L);

	lua_pushinteger(L, h);
	lua_setfield(L, c, "port");
	if (need >= 0)
		lua_pushinteger(L, need);
	else
		lua_pushnil(L);
	lua_setfield(L, c, "send");
	lua_pushboolean(L, hup);
	lua_setfield(L, c, "hup");
	lua_pop(L, 1);
}

static int
gatherports(lua_State *L, struct sched *s)
{
	int set, seen, parked, rec;
	int base = lua_gettop(L);
	int n = 0, i;

	s->altgen++;
	s->altnsend = 0;

	pushref(L, s->altset);		set = lua_gettop(L);
	pushref(L, s->altseen);		seen = lua_gettop(L);
	pushref(L, s->parked);		parked = lua_gettop(L);

	lua_pushnil(L);
	while (lua_next(L, parked) != 0) {
		rec = lua_gettop(L);	/* key below it, for lua_next */

		lua_rawgeti(L, rec, PR_SEND);
		if (lua_toboolean(L, -1)) {
			lua_Integer need = lua_tointeger(L, -1);

			lua_rawgeti(L, rec, PR_PORT);
			n++;
			altcase(L, set, n, lua_tointeger(L, -1), need, 0);
			s->altnsend++;
			lua_settop(L, rec - 1);	/* the key, for lua_next */
			continue;
		}
		lua_pop(L, 1);

		lua_rawgeti(L, rec, PR_PORTS);
		if (lua_toboolean(L, -1)) {
			int ps = lua_gettop(L);
			lua_Integer np = (lua_Integer)lua_rawlen(L, ps), k;

			for (k = 1; k <= np; k++) {
				lua_rawgeti(L, ps, k);
				lua_pushvalue(L, -1);
				lua_rawget(L, seen);
				if (lua_tointeger(L, -1) !=
				    (lua_Integer)s->altgen) {
					lua_pop(L, 1);
					lua_pushvalue(L, -1);
					lua_pushinteger(L, s->altgen);
					lua_rawset(L, seen);
					n++;
					altcase(L, set, n,
					    lua_tointeger(L, -1), -1, 0);
				} else {
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
			}
			lua_settop(L, rec);
			lua_pop(L, 1);
			continue;
		}
		lua_pop(L, 1);

		lua_rawgeti(L, rec, PR_PORT);
		if (lua_toboolean(L, -1)) {
			int bare;

			/* a bare park is thread.park, whose whole job is to
			 * re-check something a wake does not carry -- a
			 * hangup, say. So it is the one case that must not
			 * sleep through the last right going away.
			 */
			lua_rawgeti(L, rec, PR_RECV);
			bare = !lua_toboolean(L, -1);
			lua_pop(L, 1);

			lua_pushvalue(L, -1);
			lua_rawget(L, seen);
			if (lua_tointeger(L, -1) != (lua_Integer)s->altgen) {
				lua_pop(L, 1);
				lua_pushvalue(L, -1);
				lua_pushinteger(L, s->altgen);
				lua_rawset(L, seen);
				n++;
				altcase(L, set, n, lua_tointeger(L, -1), -1,
				    bare);
			} else {
				lua_pop(L, 1);
			}
		}
		lua_settop(L, rec);
		lua_pop(L, 1);
	}

	for (i = n + 1; i <= s->altn; i++) {
		lua_pushnil(L);
		lua_rawseti(L, set, i);
	}
	lua_settop(L, base);
	s->altn = n;
	return n;
}

/* Ready the threads parked on port `h`. Returns 0 when nobody was
 * parked on it, and the caller falls back to waking everyone.
 */
static int
readyon(lua_State *L, struct sched *s, lua_Integer h)
{
	int woke = 0;

	pushref(L, s->parked);
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		int hit = 0;

		lua_rawgeti(L, -1, PR_PORT);
		hit = lua_isnumber(L, -1) && lua_tointeger(L, -1) == h;
		lua_pop(L, 1);
		if (!hit) {
			lua_rawgeti(L, -1, PR_PORTS);
			if (lua_toboolean(L, -1)) {
				lua_Integer np = (lua_Integer)lua_rawlen(L, -1), k;

				for (k = 1; k <= np && !hit; k++) {
					lua_rawgeti(L, -1, k);
					hit = lua_tointeger(L, -1) == h;
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
		}
		lua_pop(L, 1);		/* record; key stays for lua_next */
		if (hit) {
			ready(L, s, -1);
			woke = 1;
		}
	}
	lua_pop(L, 1);
	return woke;
}

/* Wake every port-parked thread and let each find out for itself. */
static void
readyall(lua_State *L, struct sched *s)
{
	pushref(L, s->parked);
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		int any;

		lua_rawgeti(L, -1, PR_PORT);
		any = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if (!any) {
			lua_rawgeti(L, -1, PR_PORTS);
			any = lua_toboolean(L, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
		if (any)
			ready(L, s, -1);
	}
	lua_pop(L, 1);
}

/* Register the running coroutine's park and decide whether to yield.
 *
 * Returns 1 when the caller must yield, 0 when a wake already arrived
 * between deciding to park and getting here: the token is consumed and
 * the caller loops and looks again.
 *
 * port is a handle or 0, ports and chan are stack indices or 0.
 */
static int
parkon_begin(lua_State *L, struct sched *s, lua_Integer port, int portsi,
    int chani, int isrecv)
{
	int rec, co;

	lua_pushthread(L);
	co = lua_gettop(L);
	pushrec(L, s, co);
	rec = lua_gettop(L);

	/* sys.SELF is handle 0, so the "no port" sentinel has to be
	 * negative rather than zero.
	 */
	if (port >= 0)
		lua_pushinteger(L, port);
	else
		lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_PORT);

	if (portsi != 0)
		lua_pushvalue(L, portsi);
	else
		lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_PORTS);

	if (chani != 0)
		lua_pushvalue(L, chani);
	else
		lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_CHAN);

	lua_pushboolean(L, isrecv);
	lua_rawseti(L, rec, PR_RECV);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_SEND);

	if (isrecv) {
		/* A scalar in the common case: replyport gives every thread
		 * its own port, so one waiter is normal.
		 *
		 * Registering is idempotent. recv() is a loop and a wake
		 * that delivers nothing brings the same thread straight
		 * back here; only a delivered message takes an entry off,
		 * so appending blind grows the list for the life of the
		 * proc, holding a coroutine alive for every park it ever
		 * made.
		 */
		int qbase = lua_gettop(L);

		pushref(L, s->portq);
		lua_pushinteger(L, port);
		lua_rawget(L, -2);
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_pushinteger(L, port);
			lua_pushvalue(L, co);
			lua_rawset(L, -3);
		} else if (lua_type(L, -1) == LUA_TTHREAD) {
			if (!lua_rawequal(L, -1, co)) {
				lua_createtable(L, 2, 0);
				lua_pushvalue(L, -2);
				lua_rawseti(L, -2, 1);
				lua_pushvalue(L, co);
				lua_rawseti(L, -2, 2);
				lua_pushinteger(L, port);
				lua_pushvalue(L, -2);
				lua_rawset(L, -5);
			}
		} else {
			/* Appended only when this thread is not on the list
			 * already, which is the whole list and not just its
			 * tail: two threads in recv on one port take turns
			 * being last, so each would find the other there and
			 * append, and the list would grow by two on every
			 * wake that delivered nothing.
			 *
			 * A scan, because the list is as long as the number
			 * of threads waiting on that one port -- one for a
			 * reply port, a handful for a shared one. The queue
			 * is served from the front, so an entry already on
			 * it stays where it is rather than moving to the
			 * back.
			 */
			lua_Integer nq = (lua_Integer)lua_rawlen(L, -1), k;
			int on = 0;

			for (k = 1; k <= nq && !on; k++) {
				lua_rawgeti(L, -1, k);
				on = lua_rawequal(L, -1, co);
				lua_pop(L, 1);
			}
			if (!on) {
				lua_pushvalue(L, co);
				lua_rawseti(L, -2, nq + 1);
			}
		}
		/* unwound to a mark: the branches above leave different
		 * depths, and counting pops here took `rec` off the stack
		 * on the first registration for a port
		 */
		lua_settop(L, qbase);
	} else if (port >= 0 || portsi != 0) {
		lua_pushboolean(L, 1);
		setkey(L, s->nonrecv, co);
	}

	if (haskey(L, s->woken, co)) {
		lua_pushnil(L);
		setkey(L, s->woken, co);
		clearkey(L, s->nonrecv, co);
		lua_settop(L, co - 1);
		return 0;
	}
	lua_pushvalue(L, rec);
	setkey(L, s->parked, co);
	lua_settop(L, co - 1);
	return 1;
}

/* Clear the park mark after a resume.
 *
 * A wake that landed between setting parked and the yield cleared it
 * before it was set. A running coroutine marked parked never gets
 * requeued, so it is cleared here too.
 */
static void
parkon_end(lua_State *L, struct sched *s)
{
	lua_pushthread(L);
	clearkey(L, s->parked, -1);
	lua_pop(L, 1);
}

/* Has this coroutine finished or raised? lua_status alone cannot say:
 * it reports LUA_OK for both "not started" and "finished".
 */
static int
isdead(lua_State *co)
{
	lua_Debug ar;

	switch (lua_status(co)) {
	case LUA_YIELD:
		return 0;
	case LUA_OK:
		if (lua_getstack(co, 0, &ar))
			return 0;		/* running or normal */
		return lua_gettop(co) == 0;
	default:
		return 1;
	}
}

/* Build and print the report. Runs under pcall; the arguments are the
 * coroutine and its error.
 */
static int
fault_report(lua_State *L)
{
	lua_State *co = lua_tothread(L, 1);
	const char *msg = lua_tostring(L, 2);

	/* the traceback comes from the coroutine: the resuming stack is
	 * this scheduler and says nothing about the fault. A coroutine
	 * keeps its stack until collected.
	 */
	luaL_traceback(L, co, msg != NULL ? msg : "?", 0);
	lua_getglobal(L, "print");
	lua_pushliteral(L, "thread error: ");
	lua_pushvalue(L, -3);
	lua_concat(L, 2);
	lua_call(L, 1, 0);
	return 0;
}

/* thread.exit(): end this thread, as plan 9's threadexit does. The
 * address is the sentinel; resume_one reads it and counts the thread
 * finished rather than faulted, which is the whole difference between
 * this and error("done").
 */
static const char exitkey;

static int
l_thread_exit(lua_State *L)
{
	if (!lua_isyieldable(L)) {
		return luaL_error(L, "thread.exit: not in a thread; "
		    "sys.exit ends a proc");
	}
	lua_pushlightuserdata(L, (void *)&exitkey);
	return lua_error(L);
}

/* Report a thread that raised.
 *
 * Protected: no print, or a traceback that cannot allocate, would
 * otherwise raise out of run() and kill the proc -- the one thing a
 * fault inside a thread must never do.
 */
static void
fault(lua_State *L, lua_State *co)
{
	if (!lua_checkstack(L, 4))
		return;
	lua_pushcfunction(L, fault_report);
	lua_pushthread(co);
	lua_xmove(co, L, 1);		/* the coroutine, as a value */
	lua_xmove(co, L, 1);		/* its error */
	if (lua_pcall(L, 2, 0, 0) != LUA_OK)
		lua_pop(L, 1);
}

/* Resume the coroutine at `ci` once, and decide what its yield meant.
 *
 * A coroutine can be in the ring twice, and once it has exited the
 * second entry would count one death twice: nthreads undercounts and
 * run() ends while parked threads are still alive. Dropping a dead one
 * here is the whole guard.
 */
static void
resume_one(lua_State *L, struct sched *s, int ci)
{
	lua_State *co;
	int st, nres = 0, isfair = 0;

	ci = lua_absindex(L, ci);
	co = lua_tothread(L, ci);
	if (co == NULL || isdead(co))
		return;

	lua_pushvalue(L, ci);
	lua_rawseti(L, LUA_REGISTRYINDEX, s->current);
	st = lua_resume(co, L, 0, &nres);
	lua_pushboolean(L, 0);
	lua_rawseti(L, LUA_REGISTRYINDEX, s->current);

	/* Finished or raised, which after a resume is anything but a
	 * yield. isdead cannot answer this one: a body that ended in
	 * `return x` leaves the value on the stack and reads the same as
	 * one that never started, so the count would never come down and
	 * run() would loop forever with nothing runnable.
	 */
	if (st != LUA_YIELD) {
		s->nthreads--;
		clearkey(L, s->parked, ci);
		if (st != LUA_OK && !(lua_type(co, -1) == LUA_TLIGHTUSERDATA &&
		    lua_touserdata(co, -1) == (void *)&exitkey))
			fault(L, co);
		/* and now it really does read as dead, so a duplicate ring
		 * entry is dropped rather than counted a second time
		 */
		lua_settop(co, 0);
		return;
	}
	if (haskey(L, s->parked, ci))
		return;			/* run() wakes it; nothing to queue */

	/* The first yielded value tells a voluntary yield from a cut by
	 * the count hook, which passes none. yield() passes the sched
	 * userdata, which nothing outside this file holds.
	 */
	if (nres >= 1)
		isfair = lua_touserdata(co, -nres) == (void *)s;
	lua_pop(co, nres);

	if (isfair) {
		push(L, s, ci);		/* yield() means the back of the queue */
	} else {
		/* Cut by the hook, which the thread did not choose. It goes
		 * back at the same instruction, so no sibling is seen
		 * mid-update. The proc is descheduled from inside this loop
		 * whether or not lua asks.
		 */
		lua_pushvalue(L, ci);
		lua_rawseti(L, LUA_REGISTRYINDEX, s->inplace);
	}
}

/* Push altset[i]. Returns the handle. */
static lua_Integer
altset_at(lua_State *L, struct sched *s, int i)
{
	lua_Integer h;

	pushref(L, s->altset);
	lua_rawgeti(L, -1, i);		/* the case */
	lua_getfield(L, -1, "port");
	h = lua_tointeger(L, -1);
	lua_pop(L, 3);
	return h;
}

/* Hold a message nobody was waiting for, so the next recv() on that
 * port finds it rather than losing it.
 */
static void
hold_pending(lua_State *L, struct sched *s, lua_Integer h, int mi)
{
	mi = lua_absindex(L, mi);
	pushref(L, s->pending);
	lua_pushinteger(L, h);
	lua_rawget(L, -2);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushinteger(L, h);
		lua_pushvalue(L, -2);
		lua_rawset(L, -4);
	}
	lua_pushvalue(L, mi);
	lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
	lua_pop(L, 2);
}

/* Continuation for a call in tail position: `ctx` is the stack level
 * below the called function, so what is above it is the result list.
 * Needed on every call that can park, or lua raises across the C-call
 * boundary instead of yielding.
 */
static int
retall_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	return lua_gettop(L) - (int)ctx;
}

static int run_loop(lua_State *L);

static int
run_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);

	(void)status;
	if (ctx == K_ALTMSG || ctx == K_ALTANY) {
		/* i, msg, why */
		const char *why = lua_type(L, -1) == LUA_TSTRING ?
		    lua_tostring(L, -1) : NULL;
		int woke = 0;

		if (why) {
			/* ready but not taken, or hung up: either way the
			 * case that answered is the one to wake, and the
			 * thread on it looks again for itself.
			 */
			lua_Integer h = altset_at(L, s,
			    (int)lua_tointeger(L, -3));

			woke = readyon(L, s, h);
		} else if (!lua_isnil(L, -3)) {
			lua_Integer h = altset_at(L, s,
			    (int)lua_tointeger(L, -3));

			if (!deliver(L, s, h, -2)) {
				hold_pending(L, s, h, -2);
				readyall(L, s);
			}
			woke = 1;
		}
		lua_pop(L, 3);
		/* a hangup that shared a wake with this one is not lost:
		 * alt asks about every case that wants one before it
		 * sleeps, so the next park finds it. Polling all of them
		 * here instead cost a walk of this proc's rights per case
		 * per wake.
		 */
		/* a wake we cannot attribute to a port of ours still has to
		 * be safe, so everyone gets to look. Only where a send wait
		 * was in the set: a plain recv accounts for every wake.
		 */
		if (ctx == K_ALTANY && !woke)
			readyall(L, s);
	}
	return run_loop(L);
}

/* Move staged wakeups into the ring. Runs in main, before any test for
 * something runnable, or a staged thread reads as nothing to run.
 */
static void
drain_wake(lua_State *L, struct sched *s)
{
	int w;

	pushref(L, s->wake);
	w = lua_gettop(L);
	lua_pushnil(L);
	while (lua_next(L, w) != 0) {
		lua_pop(L, 1);		/* value */
		push(L, s, -1);
		lua_pushvalue(L, -1);
		lua_pushnil(L);
		lua_rawset(L, w);
	}
	lua_pop(L, 1);
}

/* Is any key set in table `ref`? */
static int
tablehasany(lua_State *L, int ref)
{
	int any;

	pushref(L, ref);
	lua_pushnil(L);
	any = lua_next(L, -2) != 0;
	if (any)
		lua_pop(L, 2);
	lua_pop(L, 1);
	return any;
}

/* Deliver to parked threads while a sibling is still runnable.
 *
 * A thread that never parks would otherwise starve every thread that
 * does, since the take branch runs only with the ring empty. The
 * kernel cannot wake us here: this proc is running, not parked.
 */
static void
poll_ready(lua_State *L, struct sched *s)
{
	int any;

	pushref(L, s->anyready);
	lua_call(L, 0, 1);
	any = lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (!any || gatherports(L, s) == 0)
		return;
	for (;;) {
		lua_Integer h;

		pushref(L, s->altpoll);
		pushref(L, s->altset);
		lua_call(L, 1, 1);
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			return;
		}
		h = altset_at(L, s, (int)lua_tointeger(L, -1));
		lua_pop(L, 1);
		if (!readyon(L, s, h))
			return;
	}
}

static int
run_loop(lua_State *L)
{
	struct sched *s = getsched(L);

	while (s->nthreads > 0) {
		int inplace, runnable;

		drain_wake(L, s);

		pushref(L, s->inplace);
		inplace = lua_toboolean(L, -1);
		lua_pop(L, 1);

		/* a thread resuming in place counts as runnable: it gets
		 * the cpu straight back, so without this a merely slow
		 * thread would stop delivery to its siblings
		 */
		runnable = inplace || s->qhead <= s->qtail;
		if (runnable && tablehasany(L, s->parked))
			poll_ready(L, s);

		/* the thread the hook cut goes first, and keeps going */
		pushref(L, s->inplace);
		if (!lua_toboolean(L, -1)) {
			lua_pop(L, 1);
			if (!pop(L, s)) {
				lua_pop(L, 1);
				goto blocked;
			}
		}
		lua_pushboolean(L, 0);
		lua_rawseti(L, LUA_REGISTRYINDEX, s->inplace);
		resume_one(L, s, -1);
		lua_pop(L, 1);

		/* The count hook cut that thread, and this loop is C: no
		 * lua instruction of ours will trip the armed hook, so the
		 * proc has to give the kernel its turn by hand. Once per
		 * cut, then the thread carries on where it stopped.
		 */
		pushref(L, s->inplace);
		inplace = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if (inplace)
			lua_yieldk(L, 0, K_YIELD, run_k);
		continue;

blocked:
		if (gatherports(L, s) == 0)
			return luaL_error(L,
			    "deadlock: all threads parked on channels");
		if (!tablehasany(L, s->nonrecv)) {
			/* every waiter is a plain recv(): the message is
			 * taken there and handed over here, with no wake to
			 * go looking
			 */
			pushref(L, s->alt);
			pushref(L, s->altset);
			lua_callk(L, 1, 3, K_ALTMSG, run_k);
			return run_k(L, LUA_OK, K_ALTMSG);
		}
		/* wake, not take: a port here may be waited on to send as
		 * well as to receive, and only the thread that waits to
		 * receive should be given a message.
		 */
		pushref(L, s->alt);
		pushref(L, s->altset);
		lua_pushboolean(L, 1);		/* wake */
		lua_callk(L, 2, 3, K_ALTANY, run_k);
		return run_k(L, LUA_OK, K_ALTANY);
	}
	return 0;
}

/* thread.run(): run until every thread finishes. The proc's event loop. */
static int
l_run(lua_State *L)
{
	return run_loop(L);
}

/* thread.spawn(fn, ...) -> co
 *
 * The coroutine already carries the kernel's count hook: lua_newthread
 * copies hook, mask and count from the parent.
 */
static int
l_spawn(lua_State *L)
{
	struct sched *s = getsched(L);
	int n = lua_gettop(L);
	lua_State *co;

	luaL_checktype(L, 1, LUA_TFUNCTION);
	co = lua_newthread(L);
	lua_insert(L, 1);		/* co, fn, ... */
	lua_xmove(L, co, n);
	s->nthreads++;
	lua_pushboolean(L, 1);
	setkey(L, s->wake, 1);
	return 1;
}

/* thread._ready(co) */
static int
l_ready(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTHREAD);
	ready(L, getsched(L), 1);
	return 0;
}

/* __index for the module table: thread._n is the live thread count,
 * which is scheduler state and not a field.
 */
static int
l_index(lua_State *L)
{
	const char *k = lua_tostring(L, 2);

	if (k == NULL) {
		lua_pushnil(L);
		return 1;
	}
	if (strcmp(k, "_n") == 0) {
		lua_pushinteger(L, getsched(L)->nthreads);
		return 1;
	}
	/* every coroutine registered as a recv waiter, over all ports. A
	 * count that climbs with no new threads is portq leaking.
	 */
	if (strcmp(k, "_nwaiters") == 0) {
		struct sched *s = getsched(L);
		lua_Integer n = 0;
		int q;

		pushref(L, s->portq);
		q = lua_gettop(L);
		lua_pushnil(L);
		while (lua_next(L, q) != 0) {
			n += lua_type(L, -1) == LUA_TTHREAD ? 1
			    : (lua_Integer)lua_rawlen(L, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
		lua_pushinteger(L, n);
		return 1;
	}
	lua_pushnil(L);
	return 1;
}

/* thread.inthread() -> true while a thread is running. */
static int
l_inthread(lua_State *L)
{
	struct sched *s = getsched(L);

	pushref(L, s->current);
	if (!lua_toboolean(L, -1)) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushthread(L);
	lua_pushboolean(L, lua_rawequal(L, -1, -2));
	return 1;
}

/* thread.yield(): give up the cpu without parking.
 *
 * Yields the sched userdata as its own sentinel. The count hook's
 * yield passes no values, which is how the two are told apart.
 */
static int
l_yield(lua_State *L)
{
	lua_pushvalue(L, lua_upvalueindex(1));
	return lua_yield(L, 1);
}

/* ---- Channel: libthread flavor, cap 0 is a rendezvous ----
 *
 * The table keeps its lua shape (cap, buf, sendq, recvq, closed) so
 * code reading those fields still works.
 */

#define CHANMT	"los.thread.Channel"

/* Remove and push t[1], shifting the rest down. Pushes nil if empty. */
static void
listshift(lua_State *L, int ti)
{
	lua_Integer n, i;

	ti = lua_absindex(L, ti);
	n = (lua_Integer)lua_rawlen(L, ti);
	if (n == 0) {
		lua_pushnil(L);
		return;
	}
	lua_rawgeti(L, ti, 1);
	for (i = 1; i < n; i++) {
		lua_rawgeti(L, ti, i + 1);
		lua_rawseti(L, ti, i);
	}
	lua_pushnil(L);
	lua_rawseti(L, ti, n);
}

/* Wake every receiver parked on this channel.
 *
 * An entry off the queue and not yet readied is the state that must not
 * be left behind: nothing would wake it again.
 */
static void
wakercv(lua_State *L, struct sched *s, int ci)
{
	ci = lua_absindex(L, ci);
	lua_getfield(L, ci, "recvq");
	while (lua_rawlen(L, -1) > 0) {
		listshift(L, -1);
		lua_getfield(L, -1, "co");
		if (!lua_isnil(L, -1))
			ready(L, s, -1);
		lua_pop(L, 2);
	}
	lua_pop(L, 1);
}

/* chan:nbsend(v) -> true if it went. Raises on a closed channel. */
static int
l_nbsend(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer nbuf, cap;

	luaL_checktype(L, 1, LUA_TTABLE);
	lua_getfield(L, 1, "closed");
	if (lua_toboolean(L, -1))
		return luaL_error(L, "send on closed channel");
	lua_pop(L, 1);

	lua_getfield(L, 1, "cap");
	cap = lua_tointeger(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, 1, "buf");
	nbuf = (lua_Integer)lua_rawlen(L, -1);
	if (nbuf < cap) {
		lua_pushvalue(L, 2);
		lua_rawseti(L, -2, nbuf + 1);
		lua_pop(L, 1);
		wakercv(L, s, 1);
		lua_pushboolean(L, 1);
		return 1;
	}
	lua_pop(L, 1);

	lua_getfield(L, 1, "recvq");
	if (cap == 0 && lua_rawlen(L, -1) > 0) {
		/* rendezvous with a parked receiver: deposit the value */
		lua_pop(L, 1);
		lua_getfield(L, 1, "sendq");
		lua_createtable(L, 0, 2);
		lua_pushvalue(L, 2);
		lua_setfield(L, -2, "v");
		lua_pushboolean(L, 1);
		lua_setfield(L, -2, "done");
		lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
		lua_pop(L, 1);
		wakercv(L, s, 1);
		lua_pushboolean(L, 1);
		return 1;
	}
	lua_pop(L, 1);
	lua_pushboolean(L, 0);
	return 1;
}

/* chan:nbrecv() -> ok, v, closed
 *
 * `closed` is only true once the channel has drained, so a value that
 * was sent is always received first.
 */
static int
l_nbrecv(lua_State *L)
{
	struct sched *s = getsched(L);
	int buf, sendq;

	luaL_checktype(L, 1, LUA_TTABLE);
	lua_getfield(L, 1, "buf");
	buf = lua_gettop(L);
	lua_getfield(L, 1, "sendq");
	sendq = lua_gettop(L);

	if (lua_rawlen(L, buf) > 0) {
		listshift(L, buf);		/* the value */
		listshift(L, sendq);		/* a waiting sender, maybe */
		if (!lua_isnil(L, -1)) {
			lua_getfield(L, -1, "v");
			lua_rawseti(L, buf, (lua_Integer)lua_rawlen(L, buf) + 1);
			lua_pushboolean(L, 1);
			lua_setfield(L, -2, "done");
			lua_getfield(L, -1, "co");
			if (!lua_isnil(L, -1))
				ready(L, s, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
		lua_pushboolean(L, 1);
		lua_insert(L, -2);
		return 2;
	}

	listshift(L, sendq);
	if (!lua_isnil(L, -1)) {
		lua_pushboolean(L, 1);
		lua_setfield(L, -2, "done");
		lua_getfield(L, -1, "co");
		if (!lua_isnil(L, -1))
			ready(L, s, -1);
		lua_pop(L, 1);
		lua_getfield(L, -1, "v");
		lua_pushboolean(L, 1);
		lua_insert(L, -2);
		return 2;
	}
	lua_pop(L, 1);

	lua_getfield(L, 1, "closed");
	if (lua_toboolean(L, -1)) {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
		lua_pushboolean(L, 1);
		return 3;
	}
	lua_pushboolean(L, 0);
	return 1;
}

/* chan:close(): no more values will be sent. Idempotent.
 *
 * Wakes receivers so they drain and then see the close, and parked
 * senders so they raise instead of parking forever. A deposited
 * rendezvous value is left for a receiver to take.
 */
static int
l_chanclose(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer n, i, keep = 0;
	int sendq;

	luaL_checktype(L, 1, LUA_TTABLE);
	lua_getfield(L, 1, "closed");
	if (lua_toboolean(L, -1))
		return 0;
	lua_pop(L, 1);
	lua_pushboolean(L, 1);
	lua_setfield(L, 1, "closed");

	lua_getfield(L, 1, "sendq");
	sendq = lua_gettop(L);
	n = (lua_Integer)lua_rawlen(L, sendq);
	lua_createtable(L, (int)n, 0);
	for (i = 1; i <= n; i++) {
		lua_rawgeti(L, sendq, i);
		lua_getfield(L, -1, "co");
		if (!lua_isnil(L, -1)) {
			ready(L, s, -1);
			lua_pop(L, 2);
		} else {
			lua_pop(L, 1);
			lua_rawseti(L, -2, ++keep);
		}
	}
	lua_setfield(L, 1, "sendq");
	lua_pop(L, 1);
	wakercv(L, s, 1);
	return 0;
}

static int chansend_k(lua_State *L, int status, lua_KContext ctx);

/* chan:send(v). Parks until the value is taken. */
static int
chansend_body(lua_State *L)
{
	struct sched *s = getsched(L);

	for (;;) {
		/* r is kept at index 3 for the continuation */
		if (lua_gettop(L) < 3) {
			pushself(L, l_nbsend);
			lua_pushvalue(L, 1);
			lua_pushvalue(L, 2);
			lua_call(L, 2, 1);
			if (lua_toboolean(L, -1))
				return 0;
			lua_pop(L, 1);

			lua_createtable(L, 0, 3);
			lua_pushvalue(L, 2);
			lua_setfield(L, -2, "v");
			lua_pushthread(L);
			lua_setfield(L, -2, "co");
			lua_pushboolean(L, 0);
			lua_setfield(L, -2, "done");
			lua_getfield(L, 1, "sendq");
			lua_pushvalue(L, -2);
			lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
			lua_pop(L, 1);
			wakercv(L, s, 1);
		}
		if (parkon_begin(L, s, -1, 0, 1, 0)) {
			lua_yieldk(L, 0, 0, chansend_k);
			return chansend_k(L, LUA_OK, 0);
		}
		return chansend_k(L, LUA_OK, 0);
	}
}

static int
chansend_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);
	int done;

	(void)status;
	(void)ctx;
	parkon_end(L, s);
	lua_settop(L, 3);
	lua_getfield(L, 3, "done");
	done = lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (done)
		return 0;
	/* close() dropped us from sendq and woke us; the value was never
	 * taken, so fail rather than unlink
	 */
	lua_getfield(L, 1, "closed");
	if (lua_toboolean(L, -1))
		return luaL_error(L, "send on closed channel");
	lua_pop(L, 1);
	return chansend_body(L);
}

static int
l_chansend(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 2);
	return chansend_body(L);
}

static int chanrecv_k(lua_State *L, int status, lua_KContext ctx);

/* chan:recv() -> v, ok
 *
 * Looking and registering is one step: a sender running between them
 * would find a recvq we are not on yet, wake nobody, and leave us
 * parked on a value that had already arrived.
 */
static int
chanrecv_body(lua_State *L)
{
	struct sched *s = getsched(L);

	for (;;) {
		int ok, closed;

		lua_settop(L, 1);
		pushself(L, l_nbrecv);
		lua_pushvalue(L, 1);
		lua_call(L, 1, 3);
		ok = lua_toboolean(L, -3);
		closed = lua_toboolean(L, -1);
		if (ok) {
			lua_pop(L, 1);		/* closed */
			lua_remove(L, -2);	/* ok */
			lua_pushboolean(L, !closed);
			return 2;
		}
		lua_settop(L, 1);

		/* the waiter table stays at index 2 for the continuation */
		lua_createtable(L, 0, 1);
		lua_pushthread(L);
		lua_setfield(L, -2, "co");
		lua_getfield(L, 1, "recvq");
		lua_pushvalue(L, -2);
		lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
		lua_pop(L, 1);

		if (parkon_begin(L, s, -1, 0, 1, 0)) {
			lua_yieldk(L, 0, 0, chanrecv_k);
			return chanrecv_k(L, LUA_OK, 0);
		}
		return chanrecv_k(L, LUA_OK, 0);
	}
}

static int
chanrecv_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);
	lua_Integer n, i;

	(void)status;
	(void)ctx;
	parkon_end(L, s);
	lua_settop(L, 2);

	/* unlink our waiter */
	lua_getfield(L, 1, "recvq");
	n = (lua_Integer)lua_rawlen(L, -1);
	for (i = 1; i <= n; i++) {
		lua_rawgeti(L, -1, i);
		if (lua_rawequal(L, -1, 2)) {
			lua_Integer j;

			lua_pop(L, 1);
			for (j = i; j < n; j++) {
				lua_rawgeti(L, -1, j + 1);
				lua_rawseti(L, -2, j);
			}
			lua_pushnil(L);
			lua_rawseti(L, -2, n);
			break;
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return chanrecv_body(L);
}

/* thread.chancreate(cap) -> channel. cap 0, the default, is a rendezvous. */
static int
l_chanrecv(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 1);
	return chanrecv_body(L);
}

static int
l_chancreate(lua_State *L)
{
	lua_Integer cap = luaL_optinteger(L, 1, 0);

	lua_createtable(L, 0, 5);
	lua_pushinteger(L, cap);
	lua_setfield(L, -2, "cap");
	lua_newtable(L);
	lua_setfield(L, -2, "buf");
	lua_newtable(L);
	lua_setfield(L, -2, "sendq");
	lua_newtable(L);
	lua_setfield(L, -2, "recvq");
	lua_pushboolean(L, 0);
	lua_setfield(L, -2, "closed");
	luaL_setmetatable(L, CHANMT);
	return 1;
}

static const luaL_Reg chanlib[] = {
	{ "send", l_chansend },
	{ "recv", l_chanrecv },
	{ "nbsend", l_nbsend },
	{ "nbrecv", l_nbrecv },
	{ "close", l_chanclose },
	{ NULL, NULL },
};

/* ---- alt: select over channel recv/send and port recv ----
 *
 * cases are {c=chan, op="recv"} | {c=chan, op="send", v=} | {port=h}.
 * Returns the case index and its value. A closed channel is always
 * ready to receive and yields nil; a closed channel in a send case
 * raises. An alt-send on a rendezvous channel pairs only with an
 * already-parked receiver.
 */

/* Scratch for one coroutine's alt, reused across parks.
 *
 * Safe to reuse because alt never nests: nothing between entering and
 * leaving it can call alt again on the same coroutine.
 */
static void
scratchfor(lua_State *L, struct sched *s)
{
	lua_pushthread(L);
	getkey(L, s->altscratch, -1);
	if (!lua_isnil(L, -1)) {
		lua_remove(L, -2);
		return;
	}
	lua_pop(L, 1);
	lua_createtable(L, 0, 3);
	lua_newtable(L);
	lua_setfield(L, -2, "plist");
	lua_newtable(L);
	lua_setfield(L, -2, "marks");
	lua_newtable(L);
	lua_setfield(L, -2, "waiters");
	lua_pushvalue(L, -1);
	setkey(L, s->altscratch, -3);
	lua_remove(L, -2);
}

/* Try every case once. Returns the number of results pushed, or 0. */
static int
alt_poll(lua_State *L, struct sched *s, int n)
{
	int i;

	for (i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);		/* the case */
		lua_getfield(L, -1, "port");
		if (!lua_isnil(L, -1)) {
			pushref(L, s->tryrecv);
			lua_insert(L, -2);
			lua_call(L, 1, 2);
			if (lua_toboolean(L, -2)) {
				lua_remove(L, -2);	/* ok */
				lua_pushinteger(L, i);
				lua_insert(L, -2);
				return 2;
			}
			lua_pop(L, 3);
			continue;
		}
		lua_pop(L, 1);

		lua_getfield(L, -1, "op");
		if (lua_type(L, -1) == LUA_TSTRING &&
		    lua_tostring(L, -1)[0] == 's') {
			lua_pop(L, 1);
			pushself(L, l_nbsend);
			lua_getfield(L, -2, "c");
			lua_getfield(L, -3, "v");
			lua_call(L, 2, 1);
			if (lua_toboolean(L, -1)) {
				lua_pop(L, 2);
				lua_pushinteger(L, i);
				return 1;
			}
			lua_pop(L, 2);
			continue;
		}
		lua_pop(L, 1);
		pushself(L, l_nbrecv);
		lua_getfield(L, -2, "c");
		lua_call(L, 1, 2);
		if (lua_toboolean(L, -2)) {
			lua_remove(L, -2);
			lua_remove(L, -2);	/* the case */
			lua_pushinteger(L, i);
			lua_insert(L, -2);
			return 2;
		}
		lua_pop(L, 3);
	}
	return 0;
}

static int alt_k(lua_State *L, int status, lua_KContext ctx);

/* Put this coroutine on every channel case's recvq and collect the
 * ports. Returns the number of channel marks left behind.
 */
static int
alt_register(lua_State *L, struct sched *s, int n, int scr)
{
	int plist, marks, waiters, i, np = 0, nm = 0;
	lua_Integer old;

	lua_getfield(L, scr, "plist");	plist = lua_gettop(L);
	lua_getfield(L, scr, "marks");	marks = lua_gettop(L);
	lua_getfield(L, scr, "waiters");	waiters = lua_gettop(L);

	for (i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);
		lua_getfield(L, -1, "port");
		if (!lua_isnil(L, -1)) {
			lua_rawseti(L, plist, ++np);
			lua_pop(L, 1);
			continue;
		}
		lua_pop(L, 1);
		lua_getfield(L, -1, "op");
		if (lua_type(L, -1) == LUA_TSTRING &&
		    lua_tostring(L, -1)[0] == 's') {
			lua_pop(L, 2);
			continue;
		}
		lua_pop(L, 1);

		nm++;
		lua_rawgeti(L, waiters, nm);
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_createtable(L, 0, 1);
			lua_pushthread(L);
			lua_setfield(L, -2, "co");
			lua_pushvalue(L, -1);
			lua_rawseti(L, waiters, nm);
		}
		lua_getfield(L, -2, "c");
		lua_getfield(L, -1, "recvq");
		lua_pushvalue(L, -3);		/* the waiter */
		lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
		lua_rawseti(L, marks, nm);	/* remember the queue */
		lua_pop(L, 3);
	}
	/* only the tail of a larger previous park needs clearing */
	old = (lua_Integer)lua_rawlen(L, plist);
	for (i = np + 1; i <= (int)old; i++) {
		lua_pushnil(L);
		lua_rawseti(L, plist, i);
	}
	lua_settop(L, scr);
	return nm;
}

/* Take this coroutine back off the channel queues it joined. */
static void
alt_unregister(lua_State *L, int scr, int nm)
{
	int marks, waiters, i;

	lua_getfield(L, scr, "marks");		marks = lua_gettop(L);
	lua_getfield(L, scr, "waiters");	waiters = lua_gettop(L);
	for (i = 1; i <= nm; i++) {
		lua_Integer len, j;

		lua_rawgeti(L, marks, i);
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			continue;
		}
		lua_rawgeti(L, waiters, i);
		len = (lua_Integer)lua_rawlen(L, -2);
		for (j = 1; j <= len; j++) {
			lua_rawgeti(L, -2, j);
			if (lua_rawequal(L, -1, -2)) {
				lua_Integer k;

				lua_pop(L, 1);
				for (k = j; k < len; k++) {
					lua_rawgeti(L, -2, k + 1);
					lua_rawseti(L, -3, k);
				}
				lua_pushnil(L);
				lua_rawseti(L, -3, len);
				break;
			}
			lua_pop(L, 1);
		}
		lua_pop(L, 2);
		lua_pushboolean(L, 0);
		lua_rawseti(L, marks, i);
	}
	lua_settop(L, scr);
}

/* Number of channel marks this alt left, carried across the yield. */
static int
alt_body(lua_State *L)
{
	struct sched *s = getsched(L);
	int n = (int)lua_rawlen(L, 1);

	for (;;) {
		int nres, inth, scr, nm;

		lua_settop(L, 1);
		nres = alt_poll(L, s, n);
		if (nres > 0)
			return nres;

		pushref(L, s->current);
		inth = lua_toboolean(L, -1);
		if (inth) {
			lua_pushthread(L);
			inth = lua_rawequal(L, -1, -2);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);

		if (!inth) {
			/* No thread.run() above us, so a bare yield would
			 * never set this proc BLOCKED and the kernel would
			 * resume it forever. Block on the ports directly.
			 * Channel cases make no sense here: recvq is
			 * in-process only.
			 */
			int i;

			lua_settop(L, 1);
			for (i = 1; i <= n; i++) {
				lua_rawgeti(L, 1, i);
				lua_getfield(L, -1, "port");
				if (lua_isnil(L, -1))
					return luaL_error(L, "alt: channel "
					    "case used outside thread.run()");
				lua_pop(L, 2);
			}
			/* the caller's own cases, so the index that comes
			 * back is an index into them. A hangup is reported
			 * only where a case asked for one.
			 */
			pushref(L, s->alt);
			lua_pushvalue(L, 1);
			lua_callk(L, 1, 3, K_ALTBARE, alt_k);
			return alt_k(L, LUA_OK, K_ALTBARE);
		}

		scratchfor(L, s);
		scr = lua_gettop(L);
		nm = alt_register(L, s, n, scr);
		lua_getfield(L, scr, "plist");

		if (parkon_begin(L, s, -1, lua_gettop(L), 0, 0)) {
			lua_pop(L, 1);
			lua_pushinteger(L, nm);
			lua_yieldk(L, 0, (lua_KContext)(size_t)nm, alt_k);
			return alt_k(L, LUA_OK, (lua_KContext)(size_t)nm);
		}
		lua_pop(L, 1);
		return alt_k(L, LUA_OK, (lua_KContext)(size_t)nm);
	}
}

static int
alt_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);
	int nm;

	(void)status;

	/* the port block above, which took a message rather than merely
	 * saying one was there. i, msg, why are on the stack.
	 */
	if (ctx == K_ALTBARE) {
		const char *why = lua_type(L, -1) == LUA_TSTRING ?
		    lua_tostring(L, -1) : NULL;

		parkon_end(L, s);
		if (why && why[0] == 'h') {
			/* the case's port has no other holder: alt's third
			 * answer, as for a closed channel
			 */
			lua_pop(L, 2);
			lua_pushnil(L);
			lua_pushboolean(L, 0);
			return 3;
		}
		if (!why && !lua_isnil(L, -3)) {
			lua_pop(L, 1);
			return 2;
		}
		lua_settop(L, 1);
		return alt_body(L);
	}

	nm = (int)(size_t)ctx;
	if (nm > 0) {
		parkon_end(L, s);
		lua_settop(L, 1);
		scratchfor(L, s);
		alt_unregister(L, lua_gettop(L), nm);
		lua_pop(L, 1);
	} else {
		parkon_end(L, s);
	}
	lua_settop(L, 1);
	return alt_body(L);
}

static int
l_alt(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 1);
	return alt_body(L);
}

/* ---- port sugar ---- */

/* True when the calling coroutine is the one the scheduler resumed. */
static int
running_is_current(lua_State *L, struct sched *s)
{
	int yes;

	pushref(L, s->current);
	if (!lua_toboolean(L, -1)) {
		lua_pop(L, 1);
		return 0;
	}
	lua_pushthread(L);
	yes = lua_rawequal(L, -1, -2);
	lua_pop(L, 2);
	return yes;
}

static int recv_k(lua_State *L, int status, lua_KContext ctx);

/* thread.recv(h) -> msg. Blocks until one arrives.
 *
 * A threaded recv takes its value from the mailbox when the scheduler
 * already dequeued it, and does the receive itself otherwise.
 */
static int
recv_body(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer h = luaL_checkinteger(L, 1);

	for (;;) {
		int inth = running_is_current(L, s);

		lua_settop(L, 1);
		if (inth) {
			lua_pushthread(L);
			getkey(L, s->parkrec, -1);
			if (!lua_isnil(L, -1)) {
				lua_rawgeti(L, -1, PR_HASMAIL);
				if (lua_toboolean(L, -1)) {
					lua_pop(L, 1);
					lua_rawgeti(L, -1, PR_MAIL);
					lua_pushboolean(L, 0);
					lua_rawseti(L, -3, PR_HASMAIL);
					lua_pushboolean(L, 0);
					lua_rawseti(L, -3, PR_MAIL);
					lua_remove(L, -2);
					lua_remove(L, -2);
					return 1;
				}
				lua_pop(L, 1);
			}
			lua_pop(L, 2);

			/* a message may have been taken for this port with
			 * no taker at the time
			 */
			pushref(L, s->pending);
			lua_pushinteger(L, h);
			lua_rawget(L, -2);
			if (!lua_isnil(L, -1) && lua_rawlen(L, -1) > 0) {
				listshift(L, -1);
				lua_remove(L, -2);
				lua_remove(L, -2);
				return 1;
			}
			lua_pop(L, 2);
		}

		pushref(L, s->tryrecv);
		lua_pushinteger(L, h);
		lua_call(L, 1, 2);
		if (lua_toboolean(L, -2)) {
			lua_remove(L, -2);
			return 1;
		}
		lua_pop(L, 2);

		if (inth) {
			if (parkon_begin(L, s, h, 0, 0, 1)) {
				lua_yieldk(L, 0, 0, recv_k);
				return recv_k(L, LUA_OK, 0);
			}
			continue;
		}
		pushref(L, s->block);
		lua_pushinteger(L, h);
		lua_callk(L, 1, 0, 1, recv_k);
		return recv_k(L, LUA_OK, 1);
	}
}

static int
recv_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	if (ctx == 0)
		parkon_end(L, getsched(L));
	lua_settop(L, 1);
	return recv_body(L);
}

static int
l_recv(lua_State *L)
{
	luaL_checkinteger(L, 1);
	lua_settop(L, 1);
	return recv_body(L);
}

static int park_k(lua_State *L, int status, lua_KContext ctx);

/* thread.park(h): park on a port once, without consuming anything.
 *
 * For callers that re-check some other condition, a hangup say, after
 * waking rather than taking the next message.
 */
static int
l_park(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer h = luaL_checkinteger(L, 1);

	lua_settop(L, 1);
	if (running_is_current(L, s)) {
		if (parkon_begin(L, s, h, 0, 0, 0)) {
			lua_yieldk(L, 0, 0, park_k);
			return park_k(L, LUA_OK, 0);
		}
		return 0;
	}
	pushref(L, s->block);
	lua_pushinteger(L, h);
	lua_callk(L, 1, 0, 1, park_k);
	return 0;
}

static int
park_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	if (ctx == 0)
		parkon_end(L, getsched(L));
	return 0;
}

static int parksend_k(lua_State *L, int status, lua_KContext ctx);

/* thread.parksend(h, need): park until a port may have room.
 *
 * Inside a thread this parks the whole proc, not just this coroutine:
 * the scheduler's park reasons are receive-shaped. A server must not
 * use it, since one full port would stop it serving everyone.
 */
static int
l_parksend(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer h = luaL_checkinteger(L, 1);
	lua_Integer need = luaL_optinteger(L, 2, 0);
	int co, rec;

	lua_settop(L, 2);
	if (!running_is_current(L, s)) {
		pushref(L, s->sendblock);
		lua_pushinteger(L, h);
		lua_pushinteger(L, need);
		lua_callk(L, 2, 0, 1, parksend_k);
		return 0;
	}
	lua_pushthread(L);
	co = lua_gettop(L);
	pushrec(L, s, co);
	rec = lua_gettop(L);
	lua_pushinteger(L, h);
	lua_rawseti(L, rec, PR_PORT);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_PORTS);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_CHAN);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_RECV);
	lua_pushinteger(L, need > 0 ? need : 1);
	lua_rawseti(L, rec, PR_SEND);
	lua_pushboolean(L, 1);
	setkey(L, s->nonrecv, co);

	if (haskey(L, s->woken, co)) {
		lua_pushnil(L);
		setkey(L, s->woken, co);
		clearkey(L, s->nonrecv, co);
		lua_settop(L, 2);
		return 0;
	}
	lua_pushvalue(L, rec);
	setkey(L, s->parked, co);
	lua_settop(L, 2);
	lua_yieldk(L, 0, 0, parksend_k);
	return parksend_k(L, LUA_OK, 0);
}

static int
parksend_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);
	int co, rec;

	(void)status;
	if (ctx == 1)
		return 0;
	parkon_end(L, s);
	/* clear the send wait, or gatherports keeps asking for room */
	lua_pushthread(L);
	co = lua_gettop(L);
	pushrec(L, s, co);
	rec = lua_gettop(L);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_SEND);
	lua_pushboolean(L, 0);
	lua_rawseti(L, rec, PR_PORT);
	lua_settop(L, co - 1);
	return 0;
}

/* Close a handle, ignoring failure. */
static void
closequiet(lua_State *L, struct sched *s, lua_Integer h)
{
	pushref(L, s->close);
	lua_pushinteger(L, h);
	if (lua_pcall(L, 1, 0, 0) != LUA_OK)
		lua_pop(L, 1);
}

/* __gc for a reply port: give both handles back. */
static int
replyport_gc(lua_State *L)
{
	struct sched *s = getsched(L);

	lua_getfield(L, 1, "s");
	closequiet(L, s, lua_tointeger(L, -1));
	lua_getfield(L, 1, "h");
	closequiet(L, s, lua_tointeger(L, -1));
	return 0;
}

/* thread.replyport() -> recv handle, send right
 *
 * One port per thread, made once and reused. A thread makes one
 * synchronous call at a time, so one port serves every service it talks
 * to, and distinct ports need no tags to tell replies apart.
 *
 * A send right is published, never the port as created: {__right=}
 * copies the recv flag, which would let a service receive on it.
 */
static int
l_replyport(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer h, sr;

	lua_pushthread(L);
	getkey(L, s->replyports, -1);
	if (!lua_isnil(L, -1)) {
		lua_getfield(L, -1, "h");
		lua_getfield(L, -2, "s");
		return 2;
	}
	lua_pop(L, 1);

	pushref(L, s->newport);
	lua_pushliteral(L, "thread");
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1))
		return luaL_error(L, "out of ports");
	h = lua_tointeger(L, -1);
	lua_pop(L, 1);

	pushref(L, s->sendright);
	lua_pushinteger(L, h);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1)) {
		closequiet(L, s, h);
		return luaL_error(L, "out of rights");
	}
	sr = lua_tointeger(L, -1);
	lua_pop(L, 1);

	lua_createtable(L, 0, 2);
	lua_pushinteger(L, h);
	lua_setfield(L, -2, "h");
	lua_pushinteger(L, sr);
	lua_setfield(L, -2, "s");
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, lua_upvalueindex(1));
	lua_pushcclosure(L, replyport_gc, 1);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	lua_pushvalue(L, -1);
	setkey(L, s->replyports, -3);

	lua_getfield(L, -1, "h");
	lua_getfield(L, -2, "s");
	return 2;
}

/* thread.selfright() -> a send right to this proc's own port.
 *
 * Made once. Publishing sys.SELF would hand the far end the ability to
 * receive where every reply arrives.
 */
static int
l_selfright(lua_State *L)
{
	struct sched *s = getsched(L);

	pushref(L, s->selfsend);
	if (lua_toboolean(L, -1))
		return 1;
	lua_pop(L, 1);

	pushref(L, s->sendright);
	lua_pushinteger(L, s->selfport);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1))
		return luaL_error(L, "out of rights");
	lua_pushvalue(L, -1);
	lua_rawseti(L, LUA_REGISTRYINDEX, s->selfsend);
	return 1;
}

static int sendwait_k(lua_State *L, int status, lua_KContext ctx);

/* thread.sendwait(h, msg) -> true, or false plus the reason.
 *
 * Parks for room rather than failing when the port is full.
 */
static int
sendwait_body(lua_State *L)
{
	struct sched *s = getsched(L);

	for (;;) {
		const char *why;

		lua_settop(L, 2);
		pushref(L, s->send);
		lua_pushvalue(L, 1);
		lua_pushvalue(L, 2);
		lua_call(L, 2, 3);
		if (lua_toboolean(L, -3)) {
			lua_pushboolean(L, 1);
			return 1;
		}
		why = lua_tostring(L, -2);
		if (why == NULL || why[0] != 'f') {
			lua_pushboolean(L, 0);
			lua_pushvalue(L, -3);
			return 2;
		}
		/* the third value is the size the kernel refused, and it is
		 * what to ask room for: a wait for zero wakes on any drain
		 * and finds this message still too big
		 */
		pushself(L, l_parksend);
		lua_pushvalue(L, 1);
		lua_pushvalue(L, -3);
		lua_callk(L, 2, 0, 0, sendwait_k);
		lua_settop(L, 2);
	}
}

static int
sendwait_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	(void)ctx;
	lua_settop(L, 2);
	return sendwait_body(L);
}

static int
l_sendwait(lua_State *L)
{
	luaL_checkinteger(L, 1);
	lua_settop(L, 2);
	return sendwait_body(L);
}

static int readline_k(lua_State *L, int status, lua_KContext ctx);

/* thread.readline(cons, prompt) -> line, or nil at end of input.
 *
 * The prompt rides in the request so the console can reprint it when
 * another proc's output interrupts a half-typed line. A console that
 * has gone away is end of input: a dead port drops silently, so a
 * reader would otherwise park forever.
 */
static int
l_readline(lua_State *L)
{
	luaL_checkinteger(L, 1);
	lua_settop(L, 2);

	pushself(L, l_replyport);
	lua_call(L, 0, 2);		/* reply, send */

	pushself(L, l_sendwait);
	lua_pushvalue(L, 1);
	lua_createtable(L, 0, 3);
	lua_pushliteral(L, "readline");
	lua_setfield(L, -2, "op");
	lua_pushvalue(L, 2);
	lua_setfield(L, -2, "prompt");
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, 4);		/* the send right */
	lua_setfield(L, -2, "__right");
	lua_setfield(L, -2, "reply");
	lua_callk(L, 2, 1, 0, readline_k);
	return readline_k(L, LUA_OK, 0);
}

static int
readline_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	(void)ctx;
	if (!lua_toboolean(L, -1)) {
		lua_pushnil(L);
		return 1;
	}
	lua_settop(L, 3);		/* args, reply handle */
	pushself(L, l_recv);
	lua_pushvalue(L, 3);
	lua_callk(L, 1, 1, 3, retall_k);
	return retall_k(L, LUA_OK, 3);
}

static int sleep_k(lua_State *L, int status, lua_KContext ctx);

/* thread.sleep(ms) -> true, or false when no timer is free.
 *
 * Parks rather than spinning: a proc that stays ready stops the kernel
 * reaching its idle sleep. Resolution is the scheduler tick.
 */
static int
l_sleep(lua_State *L)
{
	struct sched *s = getsched(L);

	luaL_checkinteger(L, 1);
	lua_settop(L, 1);
	pushref(L, s->timer);
	lua_pushvalue(L, 1);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1)) {
		lua_pushboolean(L, 0);
		return 1;
	}
	pushself(L, l_recv);
	lua_pushvalue(L, 2);
	lua_callk(L, 1, 0, 0, sleep_k);
	return sleep_k(L, LUA_OK, 0);
}

static int
sleep_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);

	(void)status;
	(void)ctx;
	closequiet(L, s, lua_tointeger(L, 2));
	lua_pushboolean(L, 1);
	return 1;
}

static int recvtimeout_k(lua_State *L, int status, lua_KContext ctx);

/* thread.recvtimeout(h, ms) -> msg, or nil plus "timeout".
 *
 * The timer is closed on both paths, so a fast reply does not hold a
 * timer slot until its deadline.
 */
static int
l_recvtimeout(lua_State *L)
{
	struct sched *s = getsched(L);

	luaL_checkinteger(L, 1);
	luaL_checkinteger(L, 2);
	lua_settop(L, 2);
	pushref(L, s->timer);
	lua_pushvalue(L, 2);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1)) {
		lua_pushnil(L);
		lua_pushliteral(L, "no timer available");
		return 2;
	}
	pushself(L, l_alt);
	lua_createtable(L, 2, 0);
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, 1);
	lua_setfield(L, -2, "port");
	lua_rawseti(L, -2, 1);
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, 3);
	lua_setfield(L, -2, "port");
	lua_rawseti(L, -2, 2);
	lua_callk(L, 1, 2, 0, recvtimeout_k);
	return recvtimeout_k(L, LUA_OK, 0);
}

static int
recvtimeout_k(lua_State *L, int status, lua_KContext ctx)
{
	struct sched *s = getsched(L);
	int which;

	(void)status;
	(void)ctx;
	which = (int)lua_tointeger(L, -2);
	closequiet(L, s, lua_tointeger(L, 3));
	if (which == 2) {
		lua_pushnil(L);
		lua_pushliteral(L, "timeout");
		return 2;
	}
	return 1;
}

static int await_k(lua_State *L, int status, lua_KContext ctx);

/* thread.await(h) -> msg, or nil plus "hungup". */
static int
await_body(lua_State *L)
{
	struct sched *s = getsched(L);

	for (;;) {
		lua_settop(L, 1);
		pushref(L, s->tryrecv);
		lua_pushvalue(L, 1);
		lua_call(L, 1, 2);
		if (lua_toboolean(L, -2)) {
			lua_remove(L, -2);
			return 1;
		}
		lua_pop(L, 2);

		pushref(L, s->hungup);
		lua_pushvalue(L, 1);
		lua_call(L, 1, 1);
		if (lua_toboolean(L, -1)) {
			lua_pop(L, 1);

			/* look once more. The two tests above are separate
			 * syscalls with nothing held between them, so a
			 * server on another cpu can answer and close in the
			 * gap, leaving a reply queued on a port this would
			 * then call hung up. Being the sole holder means
			 * nobody can send again, so what is there now is
			 * all there will be.
			 */
			lua_settop(L, 1);
			pushref(L, s->tryrecv);
			lua_pushvalue(L, 1);
			lua_call(L, 1, 2);
			if (lua_toboolean(L, -2)) {
				lua_remove(L, -2);
				return 1;
			}
			lua_pop(L, 2);

			lua_pushnil(L);
			lua_pushliteral(L, "hungup");
			return 2;
		}
		lua_pop(L, 1);

		pushself(L, l_park);
		lua_pushvalue(L, 1);
		lua_callk(L, 1, 0, 0, await_k);
	}
}

static int
await_k(lua_State *L, int status, lua_KContext ctx)
{
	(void)status;
	(void)ctx;
	lua_settop(L, 1);
	return await_body(L);
}

static int
l_await(lua_State *L)
{
	luaL_checkinteger(L, 1);
	lua_settop(L, 1);
	return await_body(L);
}


/* thread.call(h, msg, replyh) -> reply, or nil plus a reason.
 *
 * Two implementations: sys.call marks the whole proc blocked, which
 * would strand a thread's siblings, so a thread sends and then awaits.
 * The block is already fused on its side, in thread.run's alt.
 *
 * Failures are "dead", "full" and "hungup". A full queue is reported
 * rather than waited out, since waiting is the caller's policy.
 */
static int
l_call(lua_State *L)
{
	struct sched *s = getsched(L);

	luaL_checkinteger(L, 1);
	lua_settop(L, 3);
	if (!running_is_current(L, s)) {
		pushref(L, s->call);
		lua_insert(L, 1);
		lua_callk(L, 3, LUA_MULTRET, 0, retall_k);
		return retall_k(L, LUA_OK, 0);
	}
	pushref(L, s->send);
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_call(L, 2, 3);
	if (!lua_toboolean(L, -3)) {
		lua_pushnil(L);
		if (lua_isnil(L, -3))
			lua_pushliteral(L, "dead");
		else
			lua_pushvalue(L, -3);
		lua_pushvalue(L, -3);	/* the refused size */
		return 3;
	}
	lua_settop(L, 3);
	pushself(L, l_await);
	lua_pushvalue(L, 3);
	lua_callk(L, 1, LUA_MULTRET, 3, retall_k);
	return retall_k(L, LUA_OK, 3);
}

/* __gc for a minted right. */
static int
giveright_gc(lua_State *L)
{
	struct sched *s = getsched(L);

	closequiet(L, s, lua_tointeger(L, lua_upvalueindex(2)));
	return 0;
}

/* thread.giveright(h) -> a {__right=} table that closes what it minted.
 *
 * For putting a capability to another port in a message. Sending copies
 * the right, so the caller's handle stays live and keeps spending one
 * of its budget; a server minting one per request and forgetting it
 * stops answering. The finalizer is a net, not the mechanism.
 *
 * Not for a right meant to outlive its message, such as one handed to
 * a child in sys.spawn's arg.
 */
static int
l_giveright(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer r;

	luaL_checkinteger(L, 1);
	pushref(L, s->sendright);
	lua_pushvalue(L, 1);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1)) {
		lua_pushnil(L);
		return 1;
	}
	r = lua_tointeger(L, -1);

	lua_createtable(L, 0, 1);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__right");
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, lua_upvalueindex(1));
	lua_pushinteger(L, r);
	lua_pushcclosure(L, giveright_gc, 2);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	return 1;
}

/* thread.rpc(dest, msg, timeout) -> reply, or nil plus a reason.
 *
 * msg.reply is filled in with this thread's reply port.
 */
static int
l_rpc(lua_State *L)
{
	struct sched *s = getsched(L);

	luaL_checkinteger(L, 1);
	luaL_checktype(L, 2, LUA_TTABLE);
	lua_settop(L, 3);

	pushself(L, l_replyport);
	lua_call(L, 0, 2);		/* reply at 4, send at 5 */

	lua_createtable(L, 0, 1);
	lua_pushvalue(L, 5);
	lua_setfield(L, -2, "__right");
	lua_setfield(L, 2, "reply");

	if (!lua_isnil(L, 3)) {
		pushref(L, s->send);
		lua_pushvalue(L, 1);
		lua_pushvalue(L, 2);
		lua_call(L, 2, 2);
		if (!lua_toboolean(L, -2)) {
			lua_pushnil(L);
			if (lua_isnil(L, -2))
				lua_pushliteral(L, "dead");
			else
				lua_pushvalue(L, -2);
			return 2;
		}
		lua_settop(L, 5);
		pushself(L, l_recvtimeout);
		lua_pushvalue(L, 4);
		lua_pushvalue(L, 3);
		lua_callk(L, 2, LUA_MULTRET, 5, retall_k);
		return retall_k(L, LUA_OK, 5);
	}
	pushself(L, l_call);
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_pushvalue(L, 4);
	lua_callk(L, 3, LUA_MULTRET, 5, retall_k);
	return retall_k(L, LUA_OK, 5);
}

/* thread._park(reason): the table form, for callers outside this file. */
static int
l_park_table(lua_State *L)
{
	struct sched *s = getsched(L);
	lua_Integer port = -1;
	int portsi = 0, chani = 0;

	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 1);
	lua_getfield(L, 1, "port");
	if (!lua_isnil(L, -1))
		port = lua_tointeger(L, -1);
	lua_getfield(L, 1, "ports");
	if (!lua_isnil(L, -1))
		portsi = lua_gettop(L);
	lua_getfield(L, 1, "chan");
	if (!lua_isnil(L, -1))
		chani = lua_gettop(L);

	if (parkon_begin(L, s, port, portsi, chani, 0)) {
		lua_yieldk(L, 0, 0, park_k);
		return park_k(L, LUA_OK, 0);
	}
	return 0;
}

static const luaL_Reg threadlib[] = {
	{ "spawn", l_spawn },
	{ "chancreate", l_chancreate },
	{ "alt", l_alt },
	{ "recv", l_recv },
	{ "park", l_park },
	{ "parksend", l_parksend },
	{ "sendwait", l_sendwait },
	{ "replyport", l_replyport },
	{ "selfright", l_selfright },
	{ "readline", l_readline },
	{ "sleep", l_sleep },
	{ "recvtimeout", l_recvtimeout },
	{ "await", l_await },
	{ "call", l_call },
	{ "giveright", l_giveright },
	{ "rpc", l_rpc },
	{ "_park", l_park_table },
	{ "exit", l_thread_exit },
	{ "run", l_run },
	{ "_ready", l_ready },
	{ "inthread", l_inthread },
	{ "yield", l_yield },
	{ NULL, NULL },
};

static int
newreftable(lua_State *L)
{
	lua_newtable(L);
	return luaL_ref(L, LUA_REGISTRYINDEX);
}

/* A ref for a slot that is sometimes empty.
 *
 * Empty is false, not nil: luaL_ref refuses nil outright, and a slot
 * nilled afterwards shortens the registry's border, so the next
 * luaL_ref hands the same number out twice.
 */
static int
newrefslot(lua_State *L)
{
	lua_pushboolean(L, 0);
	return luaL_ref(L, LUA_REGISTRYINDEX);
}

/* Keep a ref to sys[name]. */
static int
sysref(lua_State *L, int sysidx, const char *name)
{
	lua_getfield(L, sysidx, name);
	return luaL_ref(L, LUA_REGISTRYINDEX);
}

int
luaopen_los_thread(lua_State *L)
{
	struct sched *s;
	int sysidx, ud, mt;

	/* require calls this with the module name as argument 1, so no
	 * stack index here is a constant.
	 */
	s = lua_newuserdatauv(L, sizeof *s, 0);
	ud = lua_gettop(L);

	s->qhead = 1;
	s->qtail = 0;
	s->nthreads = 0;
	s->altn = 0;
	s->altnsend = 0;
	s->altgen = 0;

	s->runq = newreftable(L);
	s->parked = newreftable(L);
	s->wake = newreftable(L);
	s->woken = newreftable(L);
	s->nonrecv = newreftable(L);
	s->portq = newreftable(L);
	s->pending = newreftable(L);
	s->altset = newreftable(L);
	s->altseen = newreftable(L);

	/* weak keys: a collected coroutine takes its record with it */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushstring(L, "k");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	s->parkrec = luaL_ref(L, LUA_REGISTRYINDEX);

	lua_newtable(L);
	lua_newtable(L);
	lua_pushstring(L, "k");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	s->altscratch = luaL_ref(L, LUA_REGISTRYINDEX);

	lua_newtable(L);
	lua_newtable(L);
	lua_pushstring(L, "k");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	s->replyports = luaL_ref(L, LUA_REGISTRYINDEX);

	s->selfsend = newrefslot(L);
	s->current = newrefslot(L);
	s->inplace = newrefslot(L);

	lua_getglobal(L, "require");
	lua_pushstring(L, "los.sys");
	lua_call(L, 1, 1);
	sysidx = lua_gettop(L);
	s->anyready = sysref(L, sysidx, "anyready");
	s->altpoll = sysref(L, sysidx, "altpoll");
	s->alt = sysref(L, sysidx, "alt");
	s->hungup = sysref(L, sysidx, "hungup");
	s->block = sysref(L, sysidx, "block");
	s->tryrecv = sysref(L, sysidx, "tryrecv");
	s->sendblock = sysref(L, sysidx, "sendblock");
	s->close = sysref(L, sysidx, "close");
	s->send = sysref(L, sysidx, "send");
	s->timer = sysref(L, sysidx, "timer");
	s->newport = sysref(L, sysidx, "newport");
	s->sendright = sysref(L, sysidx, "sendright");
	s->call = sysref(L, sysidx, "call");
	lua_getfield(L, sysidx, "SELF");
	s->selfport = lua_tointeger(L, -1);
	lua_settop(L, sysidx - 1);	/* done with sys */

	luaL_newmetatable(L, CHANMT);
	mt = lua_gettop(L);
	lua_pushvalue(L, ud);
	luaL_setfuncs(L, chanlib, 1);
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");

	/* the userdata is the shared upvalue of every entry point */
	luaL_newlibtable(L, threadlib);
	lua_pushvalue(L, ud);
	luaL_setfuncs(L, threadlib, 1);
	lua_pushvalue(L, mt);
	lua_setfield(L, -2, "Channel");

	/* thread._n, the live thread count, is state rather than a field */
	lua_createtable(L, 0, 1);
	lua_pushvalue(L, ud);
	lua_pushcclosure(L, l_index, 1);
	lua_setfield(L, -2, "__index");
	lua_setmetatable(L, -2);
	return 1;
}
