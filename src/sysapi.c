/* the los.sys syscalls: what lua may ask the kernel for, and what each
 * asking has to hold first.
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
#include "revision.h"
#include "kproc.h"
#include "serialize.h"
#include "timer.h"
#include "ksched.h"
#include "port.h"
#include "proc.h"
#include "sysapi.h"
#include "platform.h"

#define LOGCHUNK 2048	/* the most one sys.dmesg call copies */

/* registry keys, used for their addresses: the string.format a proc was
 * born with, so sys.log formats with the real one whatever the proc
 * does to string later, and the proc's sys.atexit list.
 */
const char fmtkey = 0;
const char atexit_key = 0;

/* the ceiling on a trace ring, sized so one directory listing fits
 * without wrapping. See docs/proc.md.
 */
#define TRACEMAX	16384
/* the fallback row count, used only if the exact table cannot be
 * allocated. See tracehist_body for why exact matters.
 */
#define HISTMAX 256

struct histrow {
	int line;
	unsigned short src;
	unsigned int count;
	unsigned long long cpu;
	unsigned long long wall;
};

static int owned_close(lua_State *L);
static int call_k(lua_State *L, int status, lua_KContext ctx);
static int set_trace_k(lua_State *L, int status, lua_KContext ctx);
static int dump_writer(lua_State *L, const void *src, size_t sz, void *ud);
static int api_stack_k(lua_State *L, int status, lua_KContext ctx);
static int stack_walk(lua_State *L);
static const luaL_Reg kapi[];
static int trace_read_k(lua_State *L, int status, lua_KContext ctx);
static int tracehist_read_k(lua_State *L, int status, lua_KContext ctx);

struct dumpbuf {
	char *data;
	size_t len, cap;
};
static int port_owner(const struct kport *port);

/* A proc about to block holds no waits: a blocked proc is not running,
 * so it cannot ask to block again. Reaching here with waits attached
 * means the last block never stopped this proc -- a yield that did not
 * unwind to the kernel. One port then carries two waiters for one proc,
 * and the waker walks an entry wait_clear has freed.
 *
 * The test sits at each call site rather than in a helper: it reads
 * shared state and belongs inside the region guarding wait_add, while
 * the raise must sit outside it, because luaL_error jumps.
 */
#define BLOCKED_TWICE_MSG "already blocked (sys.block from a coroutine? " \
	"use los.thread's park)"

static int altready(lua_State *L, struct kproc *p);
static int alt_take(lua_State *L, struct kproc *p, int wake);
static int alt_hup(lua_State *L, struct kproc *p, int n);

/* the tail of api_alt, after the proc has been woken. Nothing is a
 * legal answer and means "go round again": another proc may have taken
 * what woke this one, and a hangup wakes every waiter.
 */
static int
alt_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	int got, n = 0;
	int wanthup = lua_toboolean(L, 3);
	int wake = lua_toboolean(L, 4);

	(void)status;
	(void)ctx;
	luaL_checkstack(L, 4, "alt");

	/* outside the region, since luaL_len can raise */
	if (wanthup)
		n = (int)luaL_len(L, 1);

	ipclock_enter();
	got = alt_take(L, p, wake);
	if (!got && wanthup)
		got = alt_hup(L, p, n);
	ipclock_leave();

	if (got < 0)
		return popfail(L, p, got);
	return got;
}

/* an alt set may carry send waits as well as receive waits: sends[i] is
 * the size entry i wants room for, and anything else makes entry i an
 * ordinary receive. A parallel table rather than a box per entry, so
 * the common all-receive call passes nothing extra and builds no
 * garbage. -1 means "not a send wait", since a send of zero bytes is a
 * real question.
 */
static lua_Integer
altneed(lua_State *L, int i)
{
	lua_Integer need = -1;

	if (!lua_istable(L, 2))
		return -1;
	lua_rawgeti(L, 2, i);
	if (lua_isinteger(L, -1))
		need = lua_tointeger(L, -1);
	lua_pop(L, 1);
	return need < 0 ? -1 : need;
}

/* which entry of the handle table at stack index 1 is ready, or 0 for
 * none. The index rather than the handle, so the caller can find it
 * again in the table it passed.
 *
 * Advisory, and it must stay that way: it answers a level question,
 * which goes stale the moment a second cpu exists. Every caller
 * re-checks with a real receive and parks again if it lost the race, so
 * a wrong answer costs a wasted wake and can never lose a message.
 */
static int
altready(lua_State *L, struct kproc *p)
{
	if (!lua_istable(L, 1))
		return 0;

	int n = (int)luaL_len(L, 1);

	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, 1, i);

		struct right *r = right_get(p, (int)lua_tointeger(L, -1));

		lua_pop(L, 1);
		if (!r)
			continue;

		lua_Integer need = altneed(L, i);

		if (need >= 0) {
			/* a send wait is ready when the message would fit
			 * -- or when the port is dead, since then the send
			 * itself is what should report it.
			 */
			if (r->port->dead ||
			    r->port->qbytes + (size_t)need <= MAXQUEUE)
				return i;
		} else if (r->recv && r->port->head) {
			return i;
		}
	}
	return 0;
}

/* take the first available message from a set of receive rights, never
 * having merely looked at one. Peeking answers a level question that
 * goes stale as soon as a second cpu exists, and the answer is not a
 * better peek but holding the port across the check and the dequeue.
 * Go's chansend and 9front's altexec both do this; neither ever wakes a
 * waiter to let it look for itself.
 *
 * Returns index, message. The index is into the caller's own table, so
 * it can tell which port answered.
 */
static int
alt_take_at(lua_State *L, struct kproc *p, int i)
{
	lua_rawgeti(L, 1, i);

	struct right *r = right_get(p, (int)lua_tointeger(L, -1));

	lua_pop(L, 1);
	if (!r || !r->recv || !r->port->head)
		return 0;	/* cannot happen today; see the note above */
	lua_pushinteger(L, i);

	struct kmsg *m = port_pop(r->port);

	if (!m)
		return -1;

	int rc = msg_to_lua(L, p, m);

	/* carried out rather than raised: this runs inside the region and
	 * popfail longjmps. The caller names it once outside, and the
	 * value is popfail's own, so "out of rights" survives the trip.
	 */
	if (rc)
		return rc < -1 ? -2 : -1;
	return 2;
}

/* the same, answering in the three values sys.alt speaks: the index,
 * the message, and why. A send wait has room rather than a message, so
 * it says so and hands back nothing to deliver.
 */
static int
alt_take(lua_State *L, struct kproc *p, int wake)
{
	int i = altready(L, p);
	int rc;

	if (!i)
		return 0;
	if (wake) {
		lua_pushinteger(L, i);
		lua_pushnil(L);
		lua_pushliteral(L, "ready");
		return 3;
	}
	if (altneed(L, i) >= 0) {
		lua_pushinteger(L, i);
		lua_pushnil(L);
		lua_pushliteral(L, "send");
		return 3;
	}
	rc = alt_take_at(L, p, i);
	if (rc <= 0)
		return rc;
	lua_pushnil(L);			/* why: a message needs no reason */
	return 3;
}

/* the hangup half of the take, inside its region: asked
 * separately it is two syscalls with a gap, and a sender can answer and
 * close in it. Only where the caller asked -- sole_holder walks this
 * proc's rights per port, and thread.run parks here every round with
 * every waiting port. n comes from outside: luaL_len can raise.
 */
static int
alt_hup(lua_State *L, struct kproc *p, int n)
{
	for (int i = 1; i <= n; i++) {
		struct right *r;

		lua_rawgeti(L, 1, i);
		r = right_get(p, (int)lua_tointeger(L, -1));
		lua_pop(L, 1);
		/* a port with something queued is not finished, however
		 * few rights are left: the take above just found nothing
		 * on it, so this is only about who can still send. A send
		 * wait asks about room instead, which a port with no other
		 * holder still has.
		 */
		if (altneed(L, i) >= 0)
			continue;
		if (r && r->recv && !r->port->head &&
		    sole_holder(p, r->port)) {
			lua_pushinteger(L, i);
			lua_pushnil(L);
			lua_pushliteral(L, "hungup");
			return 3;
		}
	}
	return 0;
}

/* sys.alt(set [, sends [, wanthup [, wake]]]) -> i, msg, why | nothing.
 *
 * An entry is a receive wait unless sends[i] gives a size, in which
 * case it waits for room. wake names the ready entry and takes
 * nothing, for a caller that hands the port to somebody else to read.
 */
static int
api_alt(lua_State *L)
{
	struct kproc *p = self(L);

	int n, got, wanthup, wake;

	nopark(L, p);

	luaL_checktype(L, 1, LUA_TTABLE);
	n = (int)luaL_len(L, 1);
	if (n < 1)
		return luaL_error(L, "alt: need at least one port");
	wanthup = lua_toboolean(L, 3);
	wake = lua_toboolean(L, 4);
	luaL_checkstack(L, 4, "alt");		/* raises; before the region */

	/* one region: a message arriving after the take failed but during
	 * the build would be lost, and a sender that answers and closes
	 * between the take and a separate hangup check would be missed.
	 */
	ipclock_enter();

	/* why says what i means, since a message may itself be nil: none
	 * for a receive that took msg, "send" for room, "hungup" for a
	 * port whose last other holder has gone.
	 */
	got = alt_take(L, p, wake);

	/* before parking, not only after a wake: a caller that arrives
	 * once the last sender has gone would otherwise wait for a wake
	 * that has already happened.
	 */
	if (!got && wanthup)
		got = alt_hup(L, p, n);

	if (got) {
		ipclock_leave();
		if (got < 0)
			return popfail(L, p, got);
		return got;
	}

	/* the whole scan is one region. The loop adds a waiter to each
	 * port as it goes, so a sender to the first could wake this proc
	 * and clear its waiters while the loop is still adding more --
	 * leaving it asleep, already woken, with its message on a port it
	 * no longer waits on. A hang, not a wrong answer.
	 *
	 * Nothing that raises may run in here, so a handle is read with
	 * lua_tointegerx and a bad one is reported below as an outcome.
	 */
	wait_clear(p);
	for (int i = 1; i <= n; i++) {
		int isnum = 0;
		lua_Integer h;
		struct right *r;

		lua_rawgeti(L, 1, i);
		h = lua_tointegerx(L, -1, &isnum);
		lua_pop(L, 1);
		/* raise-free, so it may run in here: rawgeti and a type
		 * test, nothing that allocates or calls a metamethod.
		 */
		lua_Integer need = altneed(L, i);
		int send = need >= 0;

		if (!isnum) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "alt: bad receive right");
		}
		r = right_get(p, h);
		/* a send wait needs only a send right, for the same reason
		 * api_sendblock does: a writer waiting on its reader has no
		 * business holding the receive end.
		 */
		if (!r || (!send && !r->recv)) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, send ? "alt: bad right" :
			    "alt: bad receive right");
		}
		/* ready while the set was still being built, so answer
		 * rather than sleep. A message is taken here for the same
		 * reason alt_take does not report one: it goes stale.
		 */
		if (send && (r->port->dead ||
		    r->port->qbytes + (size_t)need <= MAXQUEUE)) {
			wait_clear(p);
			ipclock_leave();
			lua_pushinteger(L, i);
			lua_pushnil(L);
			lua_pushstring(L, wake ? "ready" : "send");
			return 3;
		}
		if (!send && r->port->head != 0 && wake) {
			wait_clear(p);
			ipclock_leave();
			lua_pushinteger(L, i);
			lua_pushnil(L);
			lua_pushliteral(L, "ready");
			return 3;
		}
		if (!send && r->port->head != 0) {
			int rc = alt_take_at(L, p, i);

			wait_clear(p);
			ipclock_leave();
			if (rc < 0)
				return popfail(L, p, rc);
			if (rc > 0) {
				lua_pushnil(L);
				return 3;
			}
			return 0;	/* taken from under us; go round */
		}
		/* dedup: the caller may list the same handle more than once,
		 * since alt cases share ports. two waits on one port would
		 * both fire and both be released by wait_clear, so this is
		 * about not consuming the pool rather than correctness.
		 *
		 * on the kind as well as the port: wake_senders and
		 * wake_receivers walk the same list and skip what is not
		 * theirs, so one port waited on both ways needs one of each.
		 */
		int seen = 0;
		struct waiter *w;

		SLIST_FOREACH(w, &p->waiters, pw)
			if (w->port == r->port && w->send == send) {
				seen = 1;
				break;
			}
		if (!seen && !wait_add(p, r->port, send)) {
			wait_clear(p);
			ipclock_leave();
			return luaL_error(L, "alt: out of waiters");
		}
	}
	proc_block(p);
	ipclock_leave();
	return lua_yieldk(L, 0, 0, alt_k);
}

/* sys.altpoll(set) -> index | nil. alt's non-blocking half, for a
 * proc that is still runnable and only wants to know whether any of its
 * parked threads could make progress. without it los.thread has to wake
 * every parked thread to have each one find out for itself, which is
 * O(threads) coroutine resumes to deliver one message.
 */
static int
api_altpoll(lua_State *L)
{
	struct kproc *p = self(L);
	int i;

	luaL_checktype(L, 1, LUA_TTABLE);
	i = altready(L, p);
	if (!i)
		return 0;
	lua_pushinteger(L, i);
	return 1;
}

/* sys.anyready() -> bool. Does any port this proc can receive on have a
 * message waiting? The question a runnable proc cannot otherwise ask: a
 * push wakes whoever is parked, which does nothing for a proc already
 * running, so a thread that never parks would not learn that a message
 * arrived for a parked sibling.
 *
 * Coarser and much cheaper than sys.altpoll -- no table, just a scan of
 * this proc's own rights. It answers "is a sweep worth doing", so a
 * scheduler can ask every round and pay for altpoll only when it is.
 */
static int
api_anyready(lua_State *L)
{
	struct kproc *p = self(L);

	for (int i = 0; i < p->rhigh; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used && r->recv && r->port->head) {
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	lua_pushboolean(L, 0);
	return 1;
}

/* sys.atexit(fn): run fn when this proc's main function returns normally,
 * in the order registered's reverse (LIFO, like C atexit). The handler
 * runs after main has returned, in the main state and OUTSIDE the
 * scheduler's resume of the proc -- so it must not yield or block. That
 * is enough for the things an exit handler wants: send a last message,
 * close a right, log. It does not run on an error exit (a broke proc is
 * held for inspection, not cleaned up) nor on sys.kill.
 */
static int
api_atexit(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TFUNCTION);

	if (lua_rawgetp(L, LUA_REGISTRYINDEX, &atexit_key) != LUA_TTABLE) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_rawsetp(L, LUA_REGISTRYINDEX, &atexit_key);
	}
	lua_pushvalue(L, 1);
	lua_rawseti(L, -2, luaL_len(L, -2) + 1);
	lua_pop(L, 1);
	return 0;
}

static int
api_block(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	enum { OK, BADRIGHT, HAVEMSG, TWICE, NOWAIT } rc = OK;

	/* before the region, and so before the state change rather than
	 * after the emptiness test. nopark raises, and the region sets
	 * BLOCKED and registers a waiter inside itself -- a guard after
	 * that leaves both behind, which is what nopark exists to avoid.
	 * The cost is that a nested caller whose message is already there
	 * is refused rather than answered; the code is wrong either way
	 * and the next call is the one that hangs.
	 */
	nopark(L, p);

	/* the emptiness test and the wait_add are one region and have to
	 * be: between deciding there is no message and joining the port's
	 * waiter list, a sender on another cpu would push and find nobody
	 * to wake. That is a proc asleep on a port that already has its
	 * message, which is a hang rather than a wrong answer.
	 *
	 * So every reason to refuse is computed in here and reported out
	 * there: luaL_error longjmps, and it must not do so while this is
	 * held.
	 */
	r = right_get(p, h);
	if (!r || !r->recv) {
		rc = BADRIGHT;
		goto out;
	}
	ipclock_enter_port(r->port);
	if (r->port->head)
		rc = HAVEMSG;		/* already there, don't sleep */
	else if (!SLIST_EMPTY(&p->waiters))
		rc = TWICE;
	else if (!wait_add(p, r->port, 0))
		rc = NOWAIT;
	else {
		proc_block(p);
	}
	ipclock_leave_port(r->port);
out:

	switch (rc) {
	case BADRIGHT:
		return luaL_error(L, "bad receive right");
	case HAVEMSG:
		return 0;
	case TWICE:
		return luaL_error(L, BLOCKED_TWICE_MSG);
	case NOWAIT:
		return luaL_error(L, "out of waiters");
	case OK:
		break;
	}
	/* outside the region on purpose: a lock held across a yield is
	 * held until this proc is next resumed, which is a machine-wide
	 * stall for as long as it stays parked.
	 */
	return lua_yield(L, 0);
}

static int
api_call(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer sh = luaL_checkinteger(L, 1);	/* raises; before */
	lua_Integer rh = luaL_checkinteger(L, 3);	/* raises; before */
	struct right *r, *rr;
	int twice;

	luaL_checkany(L, 2);				/* raises; before */

	/* before the region, because it raises. sys.call blocks, so the
	 * same guard applies as to sys.block -- and it is checked before
	 * the send below, so a call that cannot wait also does not deliver
	 * a request whose answer nobody will collect.
	 */
	nopark(L, p);

	ipclock_enter();
	r = right_get(p, sh);
	rr = right_get(p, rh);
	twice = !SLIST_EMPTY(&p->waiters);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "call: bad right");
	if (!rr || !rr->recv)
		return luaL_error(L, "call: bad reply right");
	/* before the send, not after: refusing a call we cannot finish is
	 * better than delivering a request whose answer nobody will collect.
	 *
	 * checked even though call_k takes an already-queued reply without
	 * yielding at all -- a call that happens to work from a coroutine
	 * when the server is same-proc and corrupts the waiter list when it
	 * is not is worse than one that always refuses. los.thread's call()
	 * is the shape for a thread, and picks this only at the top level.
	 */
	if (twice)
		return luaL_error(L, BLOCKED_TWICE_MSG);

	ipclock_enter();
	size_t len = 0;
	int rc = port_send_from_lua(L, p, r, 2, &len);

	ipclock_leave();

	if (rc == SEND_UNSERIALIZABLE)
		return luaL_error(L, "unserializable message");
	if (rc == SEND_NOMEM)
		return luaL_error(L, "out of memory queueing message");
	if (rc == SEND_DEAD) {
		lua_pushnil(L);
		lua_pushliteral(L, "dead");
		return 2;
	}
	/* the refused size third, as sys.send reports it, so a caller whose
	 * policy is to wait has the figure without sending twice to learn
	 * it.
	 */
	if (rc == SEND_FULL) {
		lua_pushnil(L);
		lua_pushliteral(L, "full");
		lua_pushinteger(L, (lua_Integer)len);
		return 3;
	}
	/* the reply may already be queued -- a same-proc service, or one
	 * that ran between our send and here -- in which case call_k takes
	 * it without yielding at all.
	 */
	return call_k(L, LUA_OK, (lua_KContext)rh);
}

static int
api_close(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before the lock */
	struct right *r;

	ipclock_enter();
	r = right_get(p, h);
	if (r && h != 0)
		right_drop(p, r);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "bad right");
	if (h == 0)
		return luaL_error(L, "cannot close self port");
	if ((int)h < p->rhint)
		p->rhint = (int)h;	/* reuse the slot we just freed */
	return 0;
}

static int
api_dmesg(lua_State *L)
{
	lua_Integer from = luaL_optinteger(L, 1, -1);
	lua_Integer max = luaL_optinteger(L, 2, LOGCHUNK);
	char buf[LOGCHUNK];
	unsigned long long next, dropped;
	size_t n;

	if (max <= 0 || max > LOGCHUNK)
		max = LOGCHUNK;
	n = kernel_dmesg((long long)from, buf, (size_t)max, &next, &dropped);
	lua_pushlstring(L, buf, n);
	lua_pushinteger(L, (lua_Integer)next);
	lua_pushinteger(L, (lua_Integer)dropped);
	return 3;
}

/* sys.granted(): {name = handle} for every capability the kernel
 * handed this proc at spawn. empty for an ordinary sys.spawn child,
 * which is granted nothing; populated for the boot payload. absent key
 * means "this machine doesn't have that" -- see struct grant.
 */
static int
api_granted(lua_State *L)
{
	struct kproc *p = self(L);
	struct grant *g;

	lua_newtable(L);
	SLIST_FOREACH(g, &p->grants, e) {
		lua_pushinteger(L, g->handle);
		lua_setfield(L, -2, g->name);
	}
	return 1;
}

/* sys.hangups() -> a counter that changes whenever any port anywhere
 * loses a reference. A ready-port hint can never name a hangup, because
 * the thread that must notice its peer is gone has nothing queued. So a
 * scheduler watches this instead, at one compare per pass, and wakes
 * everyone only when the answer to sys.hungup could have changed.
 *
 * Machine-wide rather than per-port: it is a "go look" edge, and the
 * looking is sys.hungup.
 */
static int
api_hangups(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)port_hangups());
	return 1;
}

/* sys.hungup(h): is this proc the only holder of the port behind h?
 * That is our eof, and the formulation matters. Plan 9's pipes count
 * opens of each end, which they can because a Chan is explicitly a read
 * or a write end. Rights make no such distinction -- any right can send
 * -- so "no senders left" is not a question this model can answer. "Am
 * I the only holder" is, and for a pipe it means the same thing.
 * In-flight rights still count, so a right on its way to a new writer
 * keeps it open. A pipe's creator must drop its own right, or eof never
 * arrives.
 */
static int
api_hungup(lua_State *L)
{
	struct kproc *p = self(L);
	struct right *r = right_get(p, luaL_checkinteger(L, 1));

	if (!r)
		return luaL_error(L, "bad right");

	lua_pushboolean(L, sole_holder(p, r->port));
	return 1;
}

/* sys.kill(pid): stop a proc that will not stop on its own. The
 * cooperative path is the hangup cascade, and this is the backstop for
 * a loop that never parks. The target becomes a corpse exactly as a
 * crash makes one, held BROKE for inspection and reaping. Killing self
 * is refused: freeing the caller mid-syscall is not smuggled in here.
 *
 * The authority is a right to the target's self port, which sys.spawn
 * returns to the parent: a supervisor may stop what it started, and a
 * proc that learned a pid from sys.procs may not stop a stranger.
 */
static int
api_kill(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc_locked(pid);

	if (target == p)
		return luaL_error(L, "cannot kill self");
	if (target && !may_control(p, target))
		return luaL_error(L, "no right to proc %d", pid);
	if (!target || target->status == BROKE || target->status == DEAD) {
		lua_pushboolean(L, 0);	/* nothing to kill: already gone */
		return 1;
	}
	proc_break(target, "killed");
	lua_pushboolean(L, 1);
	return 1;
}

/* one diagnostic. `loud` decides whether it reaches the console as
 * well as the ring, and logmirror can still veto that -- the console
 * task clears it while the line carries a transfer.
 */
static int
logline(lua_State *L, int loud)
{
	struct kproc *p = self(L);
	const char *s = luaL_checkstring(L, 1);
	unsigned long long ms = uptime_ms();
	char buf[LOGLINE];

	int n = lua_gettop(L);

	if (n > 1) {
		/* copies to call with, so the arguments stay where they
		 * are: index 1 is what anchors `s` on the failure path,
		 * where the call has eaten everything it was passed.
		 */
		if (!lua_checkstack(L, n + 2))
			return 0;
		lua_rawgetp(L, LUA_REGISTRYINDEX, &fmtkey);
		for (int i = 1; i <= n; i++)
			lua_pushvalue(L, i);
		if (lua_pcall(L, n, 1, 0) == LUA_OK)
			s = lua_tostring(L, -1);
		else
			lua_pop(L, 1);	/* the format itself, then */
	}

	int wrote = snprintf(buf, sizeof buf, "[%5llu.%03llu] %s: %s\n",
	    ms / 1000, ms % 1000, p->name[0] ? p->name : "?", s);

	if (wrote < 0)
		return 0;

	size_t len = (size_t)wrote >= sizeof buf ? sizeof buf - 1 :
	    (size_t)wrote;

	/* a truncated line still ends one, or the next runs into it */
	if (buf[len - 1] != '\n')
		buf[len - 1] = '\n';
	if (loud && logmirror)
		kputs(buf);
	logput(buf, len);
	return 0;
}

/* sys.log(fmt, ...) -- a diagnostic, kept and not shown.
 *
 * The ring is the transcript, and sys.dmesg reads it. A service that
 * retries every fifteen seconds would otherwise own the console, so
 * the default is quiet and saying something is the deliberate act.
 */
static int
api_log(lua_State *L)
{
	return logline(L, 0);
}

/* sys.say(fmt, ...) -- a diagnostic the console sees too.
 *
 * For what a person watching the machine come up needs: init says what
 * it granted and what it started. A driver reporting on itself uses
 * sys.log, and dmesg is where that is read.
 */
static int
api_say(lua_State *L)
{
	return logline(L, 1);
}

/* sys.logmirror(on) -- whether a diagnostic also goes to the console.
 * Answers what it was, so a caller can put it back. The console task
 * clears it while the line carries a transfer; nothing else should.
 */
static int
api_logmirror(lua_State *L)
{
	int was = logmirror;

	if (lua_gettop(L) > 0)
		logmirror = lua_toboolean(L, 1);
	lua_pushboolean(L, was);
	return 1;
}

static int
api_loginfo(lua_State *L)
{
	unsigned long long seq, oldest, lost;
	size_t size;

	kernel_loginfo(&seq, &size, &oldest, &lost);
	lua_pushinteger(L, (lua_Integer)seq);
	lua_pushinteger(L, (lua_Integer)size);
	lua_pushinteger(L, (lua_Integer)oldest);
	lua_pushinteger(L, (lua_Integer)lost);
	return 4;
}

static int
api_meminfo(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	/* per proc, and only per proc: what the heap holds is a property of
	 * the machine now that every state shares one, so it is reported by
	 * sys.stats instead. Reporting it here would attribute the whole
	 * machine's heap to whichever proc was asked about.
	 */
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	/* the pooled part of mem_used, so a proc holding buffers can be
	 * told from one holding lua objects. */
	lua_pushinteger(L, (lua_Integer)p->buf_used);
	return 4;
}

/* watch a proc: when it dies, {exit=pid, normal=, reason=?} arrives on
 * our self port. watching a dead/unknown pid delivers noproc at once.
 */
static int
api_monitor(lua_State *L)
{
	struct kproc *p = self(L);
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *target = find_proc_locked(pid);

	/* a corpse is not monitorable: its death notification has already
	 * gone out, and it will never die a second time. treating BROKE as
	 * absent here is what keeps "monitor something already gone" an
	 * immediate noproc rather than a wait for an event in the past.
	 */
	if (target && target->status == BROKE)
		target = 0;
	if (!target) {
		ipclock_enter();
		notify_exit(p, pid, "noproc", -1, 0, 0, 1);
		ipclock_leave();
		lua_pushboolean(L, 1);
		return 1;
	}
	if (target == p)
		return luaL_error(L, "cannot monitor self");
	for (int i = 0; i < target->nwatch; i++)
		if (target->watchers[i] == p->id) {
			lua_pushboolean(L, 1);
			return 1;	/* already watching */
		}
	if (target->nwatch >= MAXWATCH)
		return luaL_error(L, "too many watchers");
	target->wpriv[target->nwatch] = may_control(p, target) ? 1 : 0;
	target->watchers[target->nwatch++] = p->id;
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_newport(lua_State *L)
{
	struct kproc *p = self(L);
	struct kport *port;
	int h = -1;
	/* Required, not optional. A tag that may be left out is a tag
	 * that is left out at exactly the call site that later leaks.
	 */
	const char *tag = luaL_checkstring(L, 1);
	const char *where;

	luaL_where(L, 1);
	where = lua_tostring(L, -1);
	if (!where || !*where)
		where = "?";

	/* both allocations inside one region, and the errors raised
	 * outside it: luaL_error longjmps, so nothing that raises may
	 * run while this is held.
	 */
	int over;

	ipclock_enter();
	over = !port_budget_left(p);
	port = over ? 0 : port_new();
	if (port)
		h = right_new(p, port, 1);
	ipclock_leave();

	/* told apart, because they are different faults: the machine is
	 * full, or this proc has spent what it was given.
	 */
	if (over)
		return luaL_error(L, "port limit: %d of %d in use",
		    p->nports, p->port_limit);
	if (!port)
		return luaL_error(L, "out of ports");
	if (h < 0)
		return luaL_error(L, "out of rights");

	strncpy(port->tag, tag, sizeof port->tag - 1);
	port->tag[sizeof port->tag - 1] = 0;
	strncpy(port->where, where, sizeof port->where - 1);
	port->where[sizeof port->where - 1] = 0;

	lua_pushinteger(L, h);
	return 1;
}

static int
api_owned(lua_State *L)
{
	int h = (int)luaL_checkinteger(L, 1);
	int *ud = lua_newuserdatauv(L, sizeof *ud, 0);

	*ud = h;
	if (luaL_newmetatable(L, "los.owned")) {
		lua_pushcfunction(L, owned_close);
		lua_setfield(L, -2, "__close");
	}
	lua_setmetatable(L, -2);
	return 1;
}

/* sys.pidstat(pid): everything ps wants about one proc, in one table
 * and one call, so rendering a row costs one kernel entry and adding a
 * column costs no new entry point. The single-value accessors stay,
 * because tests and /proc read them, and share push_wchan with this.
 */
static int
api_pidstat(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}

	lua_createtable(L, 0, 10);
	lua_pushinteger(L, p->id);
	lua_setfield(L, -2, "pid");
	lua_pushstring(L, p->name);
	lua_setfield(L, -2, "name");
	/* which cpu dispatches it. Distinct from "cpu" below, which is a
	 * share of one; reported so placement can be seen from a test
	 * rather than inferred from timing.
	 */
	lua_pushinteger(L, (lua_Integer)p->home);
	lua_setfield(L, -2, "home");
	lua_pushinteger(L, (lua_Integer)p->mem_used);
	lua_setfield(L, -2, "used");
	lua_pushinteger(L, (lua_Integer)p->mem_peak);
	lua_setfield(L, -2, "peak");
	lua_pushinteger(L, (lua_Integer)p->mem_limit);
	lua_setfield(L, -2, "limit");
	lua_pushinteger(L, p->weight);
	lua_setfield(L, -2, "weight");
	/* instructions between preempt hooks. Reported because it is a
	 * containment bound like mem below it, inherited from the parent
	 * the same way, and otherwise invisible -- there was no way to ask
	 * a proc what budget it was actually given.
	 */
	lua_pushinteger(L, p->reductions);
	lua_setfield(L, -2, "reductions");
	/* ports held and the cap on them, the third inherited budget */
	lua_pushinteger(L, p->nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, p->nports_peak);
	lua_setfield(L, -2, "portspeak");
	lua_pushinteger(L, p->port_limit);
	lua_setfield(L, -2, "portlimit");
	/* raw cycles this proc has spent running, which the scheduler
	 * accumulates for its own decay. It answers what a line trace
	 * cannot: the kernel's own work -- dispatch, push and pop,
	 * serializing -- appears in no proc's trace. Two reads around a
	 * piece of work attribute it across procs with nothing added to a
	 * hot path, and what the wall clock has that the sum does not is
	 * the kernel's.
	 */
	lua_pushinteger(L, (lua_Integer)p->cputime);
	lua_setfield(L, -2, "cputime");
	lua_pushinteger(L, reprioritize(p, count_runnable()));
	lua_setfield(L, -2, "pri");
	lua_pushinteger(L, (lua_Integer)p->cpu);
	lua_setfield(L, -2, "cpu");
	lua_pushinteger(L, (lua_Integer)p->nresume);
	lua_setfield(L, -2, "resumes");
	push_wchan(L, p);
	lua_setfield(L, -2, "wchan");
	return 1;
}

/* sys.ports(): one row per live port, for an ss-shaped view of where
 * messages are going and what is being refused.
 *
 * Ungated, like sys.procs(): a port index grants nothing without a
 * right to it, so this shows the shape of the system without handing
 * over any part of it.
 */
static int
api_ports(lua_State *L)
{
	lua_newtable(L);
	for (int i = 0, n = 1; i < porthigh; i++) {
		struct kport *port = portv[i];

		if (!port)
			continue;

		lua_createtable(L, 0, 9);
		lua_pushinteger(L, port->idx);
		lua_setfield(L, -2, "port");
		/* absent rather than a sentinel when no proc holds the
		 * receive right, so no valid pid can be mistaken for one.
		 */
		int owner = port_owner(port);

		if (owner >= 0) {
			lua_pushinteger(L, owner);
			lua_setfield(L, -2, "owner");
		}
		lua_pushstring(L, port->tag);
		lua_setfield(L, -2, "tag");
		lua_pushstring(L, port->where);
		lua_setfield(L, -2, "where");
		lua_pushinteger(L, port->nrights);
		lua_setfield(L, -2, "rights");
		lua_pushinteger(L, port->nrecv);
		lua_setfield(L, -2, "recv");
		lua_pushboolean(L, port->dead);
		lua_setfield(L, -2, "dead");
		lua_pushinteger(L, (lua_Integer)port->qbytes);
		lua_setfield(L, -2, "qbytes");
		lua_pushinteger(L, (lua_Integer)port->qpeak);
		lua_setfield(L, -2, "qpeak");
		lua_pushinteger(L, (lua_Integer)port->nsent);
		lua_setfield(L, -2, "sent");
		lua_pushinteger(L, (lua_Integer)port->ndrop_full);
		lua_setfield(L, -2, "dropfull");
		lua_pushinteger(L, (lua_Integer)port->ndrop_dead);
		lua_setfield(L, -2, "dropdead");
		lua_rawseti(L, -2, n++);
	}
	return 1;
}

/* sys.priority(pid) -> weight, pri, cpu. weight is the gated knob, pri
 * what the feedback computes from it, cpu per-mille of wall time
 * decayed. Reading is not gated: the same class of information
 * sys.procs and sys.meminfo hand out already.
 */
static int
api_priority(lua_State *L)
{
	int pid = (int)luaL_checkinteger(L, 1);
	struct kproc *p = find_proc_locked(pid);

	if (!p)
		return luaL_error(L, "no such proc");
	lua_pushinteger(L, p->weight);
	lua_pushinteger(L, reprioritize(p, count_runnable()));
	lua_pushinteger(L, (lua_Integer)p->cpu);
	return 3;
}

static int
api_procname(lua_State *L)
{
	struct kproc *p = self(L);

	/* a string renames this proc and answers what it was called
	 * before; a number asks after another one. Renaming is a proc
	 * saying what it is, not a claim about authority -- nothing is
	 * decided by a name, and a right is what may_control looks at.
	 */
	if (lua_type(L, 1) == LUA_TSTRING) {
		const char *s = lua_tostring(L, 1);

		lua_pushstring(L, p->name);
		snprintf(p->name, sizeof p->name, "%s", s);
		return 1;
	}
	if (!lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	lua_pushstring(L, p->name);
	return 1;
}

static int
api_procs(lua_State *L)
{
	int room = prochigh > 0 ? prochigh : 1, n = 0;
	int *ids = lua_newuserdatauv(L, room * sizeof *ids, 0);

	/* the pids are copied out first and the table built after the
	 * lock is dropped: a lua error raised inside the region would
	 * longjmp past the release. Scratch space in a userdata rather
	 * than a malloc, for the same reason -- nothing to leak.
	 */
	ipclock_enter();
	for (int i = 0; i < prochigh && n < room; i++)
		if (procv[i] && procv[i]->status != DEAD)
			ids[n++] = procv[i]->id;
	ipclock_leave();

	lua_createtable(L, n, 0);
	for (int i = 0; i < n; i++) {
		lua_pushinteger(L, ids[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* sys.reap(pid): release a corpse.
 *
 * takes the same right as sys.kill. what it destroys is already dead,
 * but it is not nothing: a corpse carries the line trace and the stack
 * that explain the death, and the supervisor about to read them is the
 * one proc that must not have it pulled out from under it.
 */
static int
api_reap(lua_State *L)
{
	struct kproc *p = find_proc_locked((int)luaL_checkinteger(L, 1));

	if (!p)
		return luaL_error(L, "no such proc");
	if (!may_control(self(L), p))
		return luaL_error(L, "no right to proc %d", p->id);
	if (p->status != BROKE)
		return luaL_error(L, "proc %d is not broke", p->id);
	proc_reap(p);
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.reclaim() -> bytes. Hand back what the lua heap holds and is not
 * using: whole chunks nothing sits in, and the large-block cache.
 * Ungated, like sys.stats: it frees memory and reveals nothing.
 */
static int
api_reclaim(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)proc_heaps_release());
	return 1;
}

static int
api_self(lua_State *L)
{
	lua_pushinteger(L, self(L)->id);
	return 1;
}

static int
api_send(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	size_t len = 0;
	int rc;

	luaL_checkany(L, 2);				/* raises; before */

	/* no lock here at all: the right lookup reads this proc's own
	 * table, which only this proc touches, and port_send_from_lua
	 * takes the one bucket it needs for as long as it needs it.
	 */
	r = right_get(p, h);
	rc = r ? port_send_from_lua(L, p, r, 2, &len) : 0;

	if (!r)
		return luaL_error(L, "bad right");

	if (rc == SEND_UNSERIALIZABLE)
		return luaL_error(L, "unserializable message");
	if (rc == SEND_DEAD) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "dead");
		return 2;
	}

	/* a full queue returns rather than raising, so the caller picks a
	 * policy for it. The kernel must not pick: it cannot tell a pipe
	 * write from a server reply, and blocking here would let one slow
	 * reader wedge a server for every other client. Same split the
	 * receive side makes, with the loop living in lua.
	 *
	 * The third value is how many bytes were refused, so that policy
	 * can be "wait for room" without lua working out how much.
	 */
	if (rc == SEND_FULL) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "full");
		lua_pushinteger(L, (lua_Integer)len);
		return 3;
	}
	if (rc == SEND_NOMEM)
		return luaL_error(L, "out of memory queueing message");
	lua_pushboolean(L, 1);
	return 1;
}

/* sys.sendblock(h, need) -- block until the port might have room for a
 * message of `need` bytes. Needs only a send right, and `need` defaults
 * to zero, which asks whether there is any room at all.
 *
 * Pass the real size. A message that is a large fraction of MAXQUEUE is
 * refused while the queue still reports room, so a caller asking for
 * zero wakes, fails to send, and parks again -- burning its slice
 * instead of sleeping. A `need` above MAXQUEUE returns rather than
 * sleeping forever, and lets the send report the failure.
 */
static int
api_sendblock(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	lua_Integer need = luaL_optinteger(L, 2, 0);	/* raises; before */
	struct right *r;
	enum { OK, BADRIGHT, NEG, DONTSLEEP, TWICE, NOWAIT } rc = OK;

	if (need < 0)
		return luaL_error(L, "negative size");

	/* before the region, because it raises and a raise under the lock
	 * leaves it held. See nopark: at entry is where it belongs anyway.
	 */
	nopark(L, p);

	/* narrowed to one bucket, and it qualifies on both counts:
	 * everything below names r->port alone, and nothing below
	 * allocates lua memory. The right lookup comes first because it
	 * says which bucket to take, which is sound because a proc's own
	 * right table is touched only while that proc runs.
	 *
	 * The room test and the wait_add are one region: a receiver
	 * draining between them would wake nobody, leaving this proc
	 * parked on a port that has the room it asked for.
	 */
	r = right_get(p, h);
	if (!r) {
		rc = BADRIGHT;
		goto out;
	}
	ipclock_enter_port(r->port);
	if (!SLIST_EMPTY(&p->waiters))
		rc = TWICE;
	else if (r->port->dead)
		rc = DONTSLEEP;		/* never drains; let the send say so */
	else if ((size_t)need > MAXQUEUE)
		rc = DONTSLEEP;		/* can never fit; same */
	else if (r->port->qbytes + (size_t)need <= MAXQUEUE)
		rc = DONTSLEEP;		/* room already */
	else if (!wait_add(p, r->port, 1))
		rc = NOWAIT;
	else {
		proc_block(p);
	}
	ipclock_leave_port(r->port);
out:

	switch (rc) {
	case BADRIGHT:
		return luaL_error(L, "bad right");
	case TWICE:
		return luaL_error(L, BLOCKED_TWICE_MSG);
	case NOWAIT:
		return luaL_error(L, "out of waiters");
	case DONTSLEEP:
		return 0;
	case NEG:
	case OK:
		break;
	}
	return lua_yield(L, 0);
}

/* sys.sendright(h) -> a new handle to the same port, send only.
 *
 * Mach's shape: a receive right is the authority to hand out send
 * rights. {__right=h} copies the recv flag, so handing out a port you
 * created would also hand out the ability to receive on it -- and on a
 * port many clients share, any of them could then take another's
 * requests, or take their own and never answer.
 */
static int
api_sendright(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer arg = luaL_checkinteger(L, 1);	/* raises; before the lock */
	struct right *r;
	int h = -1;

	ipclock_enter();
	r = right_get(p, arg);
	if (r)
		h = right_new(p, r->port, 0);
	ipclock_leave();

	if (!r)
		return luaL_error(L, "bad right");
	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, h);
	return 1;
}

/* sys.setexit(status): record this proc's exit status, reported to
 * whoever monitors it. Terminates nothing -- the proc ends however it
 * was going to. Split that way because a real exit must unwind from
 * arbitrary depth, which from C means raising, and any pcall in between
 * can swallow a raise. So lua implements os.exit as "record, then raise
 * a sentinel it catches itself".
 *   nil / 0   success
 *   n         posix status n, what a ported os.exit(1) gives
 *   "why"     plan 9's exits("why"), reported as status 1 as well
 */
static int
api_setexit(lua_State *L)
{
	struct kproc *p = self(L);

	p->exitmsg[0] = 0;
	if (lua_isnoneornil(L, 1)) {
		p->exitcode = 0;
	} else if (lua_type(L, 1) == LUA_TSTRING) {
		snprintf(p->exitmsg, sizeof p->exitmsg, "%s",
		    lua_tostring(L, 1));
		p->exitcode = 1;
	} else {
		p->exitcode = (int)luaL_checkinteger(L, 1);
	}
	return 0;
}

/* sys.exit(code|"why"): end this proc, wherever it is called from.
 * Unwinding ends one coroutine, leaving a done thread's siblings parked
 * and the proc alive. The dispatch loop reads the flag rather than this
 * freeing the state it runs in, which sys.kill refuses for the same
 * reason -- and this is a plain exit, not the corpse a kill leaves.
 */
static int
api_exit(lua_State *L)
{
	struct kproc *p = self(L);

	api_setexit(L);
	p->exiting = 1;
	return 0;
}

/* sys.set_priority(pid, weight): a policy knob, not the scheduler. It
 * writes a clamped integer that the dispatch loop reads every lap, so
 * no lua runs inside a scheduling decision and a crashing policy proc
 * cannot wedge dispatch -- the reason sched_ext bounds its programs
 * rather than letting them be the dispatcher. Weight 1 is plain
 * round-robin; higher weight is resumed up to `weight` times per lap.
 *
 * Gated on the scheduling capability, or any child could hand itself
 * the largest weight and starve every other proc.
 */
static int
api_set_priority(lua_State *L)
{
	int pid = (int)luaL_checkinteger(L, 1);
	int weight = (int)luaL_checkinteger(L, 2);
	struct kproc *p = find_proc_locked(pid);

	if (!proc_has_port(self(L), schedport))
		return luaL_error(L, "no scheduling capability");
	if (!p)
		return luaL_error(L, "no such proc");
	if (weight < 1)
		weight = 1;
	if (weight > MAXWEIGHT)
		weight = MAXWEIGHT;
	p->weight = weight;
	return 0;
}

/* sys.settime(unix), gated on a right to clockport: handle "time" in
 * sys.granted(), as set_priority is gated on schedport.
 */
static int
api_settime(lua_State *L)
{
	lua_Integer t = luaL_checkinteger(L, 1);

	if (!proc_has_port(self(L), clockport))
		return luaL_error(L, "no clock capability");
	if (t <= 0)
		return luaL_error(L, "settime: not a unix time");

	kernel_settime((long long)t);
	lua_pushinteger(L, t);
	return 1;
}

/* sys.set_torture(pid, on) -- yield between every instruction. Costs
 * the machine a real guarantee while it is on, so PRIV_BOOT only.
 *
 * Arming is by inheritance as much as by the sweep: lua_newthread
 * copies hook, mask and count from its creator, so a thread made after
 * this returns is born tortured. Turn it on before spawning the threads
 * that are meant to be cut.
 */
static int
api_set_torture(lua_State *L)
{
	struct kproc *p = self(L);
	int arg = 1;

	if (lua_gettop(L) > 1) {
		arg = 2;
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	if (!kernel_current_is_boot())
		return luaL_error(L, "no permission to torture a proc");
	if (!p->L)
		return luaL_error(L, "proc %d has no state", p->id);

	p->torture = lua_toboolean(L, arg);
	/* every instruction, or back to the calibrated budget */
	proc_armall(p, p->torture ? 1 : p->reductions);
	lua_pushboolean(L, 1);
	return 1;
}

static int
api_set_trace(lua_State *L)
{
	return set_trace_k(L, LUA_OK, 0);
}

/* sys.spawn(code_or_fn, opts) -> pid. code_or_fn is source text or a
 * plain lua function, which is dumped to bytecode here and crosses into
 * the child as bytes either way. C functions cannot be dumped, and
 * upvalues beyond _ENV do not carry values across -- the same isolation
 * limit as source text, but easier to trip, since a closure captures an
 * outer local without being asked to.
 */
static int
api_spawn(lua_State *L)
{
	struct kproc *p = self(L);
	size_t n;
	const char *code;
	struct dumpbuf buf = { 0 };
	int is_dumped = 0;

	if (lua_isfunction(L, 1)) {
		if (lua_iscfunction(L, 1))
			return luaL_error(L,
			    "spawn: cannot dump a C function");
		lua_pushvalue(L, 1);
		if (lua_dump(L, dump_writer, &buf, 0) != 0) {
			free(buf.data);
			return luaL_error(L,
			    "spawn: could not dump function (odd upvalues?)");
		}
		lua_pop(L, 1);
		code = buf.data;
		n = buf.len;
		is_dumped = 1;
	} else {
		code = luaL_checklstring(L, 1, &n);
	}
	int reductions = 0;
	int trace = 0;
	int port_limit = 0;
	size_t mem_limit = 0;
	int expendable = 0;
	char chunkname[32] = "=spawn";

	if (!lua_isnoneornil(L, 2)) {
		luaL_checktype(L, 2, LUA_TTABLE);
		/* opts.trace: arm the ring before the chunk runs.
		 *
		 * sys.set_trace cannot cover a proc that dies quickly --
		 * spawning and then arming is a race the proc usually
		 * wins, and arming a corpse is too late by definition.
		 * a short-lived proc that faults is exactly the one
		 * worth tracing, so the only place to start is before
		 * its first line.
		 */
		lua_getfield(L, 2, "trace");
		if (!lua_isnil(L, -1))
			trace = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "reductions");
		if (!lua_isnil(L, -1))
			reductions = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "mem");
		if (!lua_isnil(L, -1))
			mem_limit = (size_t)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "ports");
		if (!lua_isnil(L, -1))
			port_limit = (int)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 2, "expendable");
		if (lua_toboolean(L, -1))
			expendable = 1;
		lua_pop(L, 1);
		/* both budgets are clamped to the parent's below, so a
		 * child is never less contained than whoever spawned it.
		 */
		lua_getfield(L, 2, "name");
		if (!lua_isnil(L, -1))
			snprintf(chunkname, sizeof chunkname, "=%s",
			    luaL_checkstring(L, -1));
		lua_pop(L, 1);
	}

	/* budgets are inherited and may only be asked downward, so a child
	 * is never less contained than its parent. Absent means the
	 * parent's, and a larger request is clamped rather than refused:
	 * refusing would make a supervisor's containment its children's
	 * problem to know about.
	 *
	 * Inherited rather than divided. A cap bounds any one proc, which
	 * makes a runaway loop cost its own proc first; dividing bounds a
	 * tree, and needs an account of who spawned whom.
	 */
	if (reductions <= 0 || reductions > p->reductions)
		reductions = p->reductions;
	if (p->mem_limit && (mem_limit == 0 || mem_limit > p->mem_limit))
		mem_limit = p->mem_limit;
	if (p->port_limit && (port_limit == 0 || port_limit > p->port_limit))
		port_limit = p->port_limit;

	/* one way, like the budgets: a child of something expendable is
	 * expendable, and nothing can declare itself otherwise. A subtree
	 * that could opt out is a subtree that outlives what started it.
	 */
	if (p->expendable)
		expendable = 1;

	/* opts.arg: one value handed to the child before its chunk runs,
	 * arriving as the chunk's `...`. A message cannot do this job,
	 * because the child's first line is typically require, which runs
	 * before any receive -- so its namespace has to be there already.
	 *
	 * The kernel does not interpret it. It goes through the ordinary
	 * serializer, so rights travel as they do in any message.
	 */
	struct wbuf argw = { 0 };
	int have_arg = 0;

	if (!lua_isnoneornil(L, 2)) {
		lua_getfield(L, 2, "arg");
		if (!lua_isnil(L, -1)) {
			int bad;

			ipclock_enter();
			bad = serialize(L, -1, &argw, p, 0);
			if (bad)
				release_inflight(argw.refs, argw.refrecv,
				    argw.nrefs);
			ipclock_leave();
			if (bad) {
				free(argw.p);
				lua_pop(L, 1);
				return luaL_error(L, "spawn: unserializable arg");
			}
			have_arg = 1;
		}
		lua_pop(L, 1);
	}

	/* sys.spawn can never mint a privileged (cons/wire/power-class)
	 * proc: PRIV_NONE is hardwired here. only the kernel's own boot
	 * sequence (spawn_cons/spawn_wire/spawn_power) sets a real priv
	 * value, never reachable from lua.
	 */
	/* the region ends before the error paths below: they call
	 * release_inflight_locked, which takes this lock itself.
	 */
	ipclock_enter();
	int pid = proc_new(code, n, chunkname, 0, reductions, mem_limit,
	    port_limit, PRIV_NONE);
	struct kproc *child = pid >= 0 ? find_proc(pid) : 0;

	if (child)
		child->expendable = expendable;

	ipclock_leave();

	if (is_dumped)
		free(buf.data);	/* proc_new/luaL_loadbuffer copies, doesn't keep it */

	if (pid < 0) {
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
		return luaL_error(L, "spawn failed");
	}

	if (!child) {
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
		return luaL_error(L, "spawn: child vanished");
	}
	/* before the child has run a line, which is the whole point of
	 * asking for it here. a failure to allocate the ring is not a
	 * failure to spawn: the proc is fine, it is only untraced.
	 */
	if (trace > 0) {
		if (trace > TRACEMAX)
			trace = TRACEMAX;
		trace_arm(child, trace);
	}

	/* push the arg onto the child's stack, above the loaded chunk, so
	 * the first resume passes it as `...`.
	 */
	if (have_arg) {
		size_t off = 0;
		struct minted mt = { .n = 0 };
		int bad;

		/* writing another cpu's running coroutine would race its
		 * stack, and a raise in here would longjmp down that cpu's
		 * resume frame -- leaving this one's ipc bucket held.
		 */
		if (child->status != HATCHING)
			platform_abort("spawn: child ran before its arg");

		/* the parent loses any buffer in the arg here, before the
		 * child can take one: from this line the bytes have one
		 * owner, whether delivery works or not.
		 */
		for (int i = 0; i < argw.bufs.n; i++)
			luabuf_detach(L, argw.bufown[i]);

		ipclock_enter();
		bad = deserialize(child->co, argw.p, argw.len, &off,
		    &argw.bufs, child, 0, &mt);
		ipclock_leave();
		msgbufs_free(&argw.bufs);	/* whatever it did not take */
		if (bad) {
			/* a partial deserialize may have left values on co's
			 * stack under the chunk's feet, and rights already
			 * minted into the child. the proc is unusable; kill
			 * it rather than start it half-built -- which drops
			 * those rights with everything else it held, so
			 * there is nothing for minted_undo to do here.
			 */
			release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
			free(argw.p);
			proc_kill(child, "spawn: could not deliver arg");
			return luaL_error(L, "spawn: could not deliver arg");
		}
		child->nargs = 1;
		/* the in-flight ref taken by serialize; the child now holds
		 * its own from right_new, exactly as a delivered message
		 * releases its refs once received.
		 */
		release_inflight_locked(argw.refs, argw.refrecv, argw.nrefs);
		free(argw.p);
	}

	/* built: the arg is on co's stack and nargs says so. */
	ipclock_enter();
	proc_launch(child);
	ipclock_leave();

	/* hand parent a send right on the child's self port */
	ipclock_enter();
	int h = right_new(p, child->rights[0].port, 0);

	ipclock_leave();

	if (h < 0)
		return luaL_error(L, "out of rights");
	lua_pushinteger(L, pid);
	lua_pushinteger(L, h);
	return 2;
}

static int
api_stack(lua_State *L)
{
	return api_stack_k(L, LUA_OK, 0);
}

static int
api_stack_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, api_stack_k);
	case HOLD_SELF:
		debug_push_stacks(L, p->L, p->co);
		return 1;
	}

	/* protected: the walk builds its result in this proc's state, so
	 * it allocates, so it can raise -- and a raise past the thaw would
	 * leave the target frozen for good.
	 */
	lua_pushcfunction(L, stack_walk);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

/* sys.battery() -> millivolts, or nil where there is no pack.
 *
 * Ambient, like sys.stats: reading a voltage is an observation of the
 * machine and reaches nothing. Raw millivolts, since what counts as
 * empty belongs to whoever draws the meter.
 */
static int
api_battery(lua_State *L)
{
	int mv = 0;

	if (!platform_battery(&mv))
		return 0;
	lua_pushinteger(L, mv);
	return 1;
}

static int
api_stats(lua_State *L)
{
	int nports = 0, nprocs = 0, nbroke = 0;

	/* both tables under one hold, and counting only: the lua half is
	 * below, where a raise cannot jump past the release. Corpses are
	 * counted apart from procs -- they hold no rights and will never
	 * run, so counting them here would make "procs" disagree with
	 * nlive and read as a leak after every crash.
	 */
	ipclock_enter();
	for (int i = 0; i < porthigh; i++)
		if (portv[i])
			nports++;
	for (int i = 0; i < prochigh; i++)
		if (procv[i] && procv[i]->status == BROKE)
			nbroke++;
		else if (procv[i] && procv[i]->status != DEAD)
			nprocs++;
	ipclock_leave();

	lua_createtable(L, 0, 3);
	lua_pushinteger(L, nports);
	lua_setfield(L, -2, "ports");
	lua_pushinteger(L, nprocs);
	lua_setfield(L, -2, "procs");
	lua_pushinteger(L, nbroke);
	lua_setfield(L, -2, "broke");
	unsigned long long tidle = 0, tlaps = 0, tdisp = 0;
	unsigned long long tfull = 0, tdead = 0;

	for (unsigned i = 0; cpu_at(i); i++) {
		tidle += cpu_at(i)->nidle;
		tlaps += cpu_at(i)->nlaps;
		tdisp += cpu_at(i)->ndispatch;
		tfull += cpu_at(i)->ndrop_full;
		tdead += cpu_at(i)->ndrop_dead;
	}
	lua_pushinteger(L, (lua_Integer)tidle);
	lua_setfield(L, -2, "idles");
	lua_pushinteger(L, port_rights_high());
	lua_setfield(L, -2, "rightshigh");
	lua_pushinteger(L, (lua_Integer)tlaps);
	lua_setfield(L, -2, "laps");
	lua_pushinteger(L, (lua_Integer)tdisp);
	lua_setfield(L, -2, "dispatches");
	lua_pushinteger(L, (lua_Integer)tfull);
	lua_setfield(L, -2, "dropfull");
	lua_pushinteger(L, (lua_Integer)tdead);
	lua_setfield(L, -2, "dropdead");

	/* the firmware's view: what the machine has, and what is left. this
	 * is the ceiling the other figures sit under, since a proc is a
	 * lua_State drawn from the same pool.
	 */
	unsigned long long mtotal = 0, mavail = 0, mlargest = 0;

	platform_meminfo(&mtotal, &mavail, &mlargest);
	lua_pushinteger(L, (lua_Integer)mtotal);
	lua_setfield(L, -2, "memtotal");
	lua_pushinteger(L, (lua_Integer)mavail);
	lua_setfield(L, -2, "memavail");
	/* the largest run of memavail. A heap fragmented below what a
	 * chunk costs refuses one while memavail still looks healthy.
	 */
	lua_pushinteger(L, (lua_Integer)mlargest);
	lua_setfield(L, -2, "memlargest");

	/* and the pool the lua heaps are carved from, which on a board
	 * with PSRAM is a different one. What bounds how many procs can
	 * exist is this, not the figures above: a machine can be out of
	 * room for another heap with plenty of sram left.
	 */
	unsigned long long ctotal = 0, cavail = 0, clargest = 0;

	platform_chunkinfo(&ctotal, &cavail, &clargest);
	lua_pushinteger(L, (lua_Integer)ctotal);
	lua_setfield(L, -2, "chunktotal");
	lua_pushinteger(L, (lua_Integer)cavail);
	lua_setfield(L, -2, "chunkavail");
	lua_pushinteger(L, (lua_Integer)clargest);
	lua_setfield(L, -2, "chunklargest");

	/* the c heap, i.e. everything not on a per-proc lua heap: port
	 * messages, net tokens and payload copies, loadfile buffers.
	 * sys.meminfo(pid) covers the lua side.
	 */
	/* zeroed, so a platform that cannot answer reports nothing rather
	 * than the stack.
	 */
	size_t hlive = 0, hpeak = 0;
	unsigned long hblocks = 0, htotal = 0;

	kheap_stats(&hlive, &hpeak, &hblocks, &htotal);
	lua_pushinteger(L, (lua_Integer)hlive);
	lua_setfield(L, -2, "heap_used");
	lua_pushinteger(L, (lua_Integer)hpeak);
	lua_setfield(L, -2, "heap_peak");
	lua_pushinteger(L, (lua_Integer)hblocks);
	lua_setfield(L, -2, "heap_blocks");
	lua_pushinteger(L, (lua_Integer)htotal);
	lua_setfield(L, -2, "heap_total_allocs");
	/* los.buf's storage, which comes from the chunk source rather than
	 * a lua heap. Counted in heap_used like every other chunk, and
	 * here on its own so it can be told apart. */
	lua_pushinteger(L, (lua_Integer)kbuf_pooled());
	lua_setfield(L, -2, "buf_used");
	/* buffers made since boot, beside the bytes held now: a rate says
	 * whether a path allocates per operation, which a level cannot.
	 */
	lua_pushinteger(L, (lua_Integer)luabuf_allocs());
	lua_setfield(L, -2, "buf_allocs");

	/* the lua heaps, summed: there is one per proc now, and what the
	 * machine wants to know is still the total. live is what the
	 * states asked for; mapped is what the machine holds to serve it,
	 * and the gap is what bounds how many procs fit.
	 *
	 * Note heap_used above counts these chunks as ordinary C
	 * allocations, since that is what they are -- so the two are not
	 * additive.
	 */
	struct luaheap_stats hs = { 0 }, one;

	/* one heap answers for the whole machine when there is one; the
	 * per-proc loop would count it once per proc.
	 */
	if (shared_heap) {
		luaheap_stats(shared_heap, &hs);
	} else {
		ipclock_enter();
		for (int i = 0; i < prochigh; i++) {
			if (!procv[i] || !procv[i]->heap)
				continue;
			luaheap_stats(procv[i]->heap, &one);
			hs.live += one.live;
			hs.peak += one.peak;
			hs.mapped += one.mapped;
			hs.waste += one.waste;
			hs.rounding += one.rounding;
			hs.headers += one.headers;
			hs.unused += one.unused;
			hs.cached += one.cached;
			hs.chunks += one.chunks;
			hs.larges += one.larges;
		}
		ipclock_leave();
	}
	lua_pushinteger(L, (lua_Integer)hs.live);
	lua_setfield(L, -2, "lua_live");
	lua_pushinteger(L, (lua_Integer)hs.mapped);
	lua_setfield(L, -2, "lua_mapped");
	lua_pushinteger(L, (lua_Integer)hs.waste);
	lua_setfield(L, -2, "lua_waste");
	/* and where that waste is, because the three answer different
	 * questions: rounding is the size classes being wrong for this
	 * target, unused is the chunk size being wrong for this working
	 * set, and headers is neither. Tuning one when the cost is in
	 * another is the mistake this exists to prevent.
	 */
	lua_pushinteger(L, (lua_Integer)hs.rounding);
	lua_setfield(L, -2, "lua_rounding");
	lua_pushinteger(L, (lua_Integer)hs.headers);
	lua_setfield(L, -2, "lua_headers");
	lua_pushinteger(L, (lua_Integer)hs.unused);
	lua_setfield(L, -2, "lua_unused");
	/* how much of unused sys.reclaim would return, so "held" can be
	 * told from "fragmented" without guessing.
	 */
	lua_pushinteger(L, (lua_Integer)hs.cached);
	lua_setfield(L, -2, "lua_cached");
	/* the tsc calibration, so a benchmark can time with sys.ticks()
	 * -- sub-nanosecond -- and still report real units. uptime_ms has
	 * 1ms granularity, which is useless over a 20ms measurement.
	 */
	lua_pushinteger(L, (lua_Integer)kernel_cyc_per_ms());
	lua_setfield(L, -2, "cycles_per_ms");
	lua_pushinteger(L, default_reductions);
	lua_setfield(L, -2, "reductions");
	/* which src/<arch> this image was built from, so nothing in lua
	 * has to hardcode the answer (init.lua's /uname did).
	 */
	lua_pushstring(L, platform_arch());
	lua_setfield(L, -2, "arch");
	/* how many cpus came up. This is the only way to ask from
	 * inside: an AP that failed to start leaves nothing behind for
	 * a proc to notice, so the count has to be reported rather than
	 * inferred.
	 */
	lua_pushinteger(L, (lua_Integer)platform_ncpu());
	lua_setfield(L, -2, "cpus");
	/* and what each of them is doing. A count alone cannot tell a
	 * machine dispatching on two cpus from one that started a second
	 * cpu and left it parked -- which is exactly what this branch
	 * did for several commits, with a passing test for it.
	 */
	lua_newtable(L);
	for (unsigned i = 0; cpu_at(i); i++) {
		struct cpu *c = cpu_at(i);

		lua_createtable(L, 0, 5);
		lua_pushinteger(L, (lua_Integer)c->apicid);
		lua_setfield(L, -2, "apicid");
		lua_pushboolean(L, c->dispatching);
		lua_setfield(L, -2, "dispatching");
		lua_pushinteger(L, (lua_Integer)c->nlaps);
		lua_setfield(L, -2, "laps");
		lua_pushinteger(L, (lua_Integer)c->ndispatch);
		lua_setfield(L, -2, "dispatched");
		lua_pushinteger(L, (lua_Integer)c->nidle);
		lua_setfield(L, -2, "idles");
		lua_rawseti(L, -2, (lua_Integer)i + 1);
	}
	lua_setfield(L, -2, "cpu");
	/* the two locks kernel.c owns, so contention is a number rather
	 * than an argument. `spin` is cycles a cpu spent waiting, and it
	 * is the figure that says whether splitting a lock would buy
	 * anything: an uncontended lock has nothing to give back.
	 */
	lua_newtable(L);
	{
		/* the buckets summed. A per-bucket breakdown would say
		 * whether the hash spreads the ports evenly, but the
		 * totals are what compares against a single lock.
		 */
		unsigned long long nlock, ncontend, spin, held;

		ipclock_stats(&nlock, &ncontend, &spin, &held);

		lua_createtable(L, 0, 4);
		lua_pushinteger(L, (lua_Integer)nlock);
		lua_setfield(L, -2, "locks");
		lua_pushinteger(L, (lua_Integer)ncontend);
		lua_setfield(L, -2, "contended");
		lua_pushinteger(L, (lua_Integer)spin);
		lua_setfield(L, -2, "spin");
		lua_pushinteger(L, (lua_Integer)held);
		lua_setfield(L, -2, "held");
		lua_pushinteger(L, (lua_Integer)port_claims(1));
		lua_setfield(L, -2, "claimwon");
		lua_pushinteger(L, (lua_Integer)port_claims(0));
		lua_setfield(L, -2, "claimlost");
		lua_setfield(L, -2, "ipc");

		lua_createtable(L, 0, 3);
		lua_pushinteger(L, (lua_Integer)schedlock.nlock);
		lua_setfield(L, -2, "locks");
		lua_pushinteger(L, (lua_Integer)schedlock.ncontend);
		lua_setfield(L, -2, "contended");
		lua_pushinteger(L, (lua_Integer)schedlock.spin);
		lua_setfield(L, -2, "spin");
		lua_setfield(L, -2, "sched");
	}
	lua_setfield(L, -2, "lock");
	return 1;
}

/* sys.syscalls(pid): how many of each los.sys call this proc has made.
 *
 * Deliberately not folded into sys.pidstat, which ps calls once per proc
 * and which should not build a thirty-eight entry table each time. Ask
 * for this when the question is "what is it doing", not "what is on the
 * machine".
 *
 * Only calls that have happened are reported, so the table is short and
 * a zero is absence rather than a row of noise.
 */
static int
api_syscalls(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}

	lua_newtable(L);
	for (int i = 0; kapi[i].name && i < NSYSCALL; i++)
		if (p->calls[i]) {
			lua_pushinteger(L, (lua_Integer)p->calls[i]);
			lua_setfield(L, -2, kapi[i].name);
		}
	return 1;
}

static int
api_ticks(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)platform_ticks());
	return 1;
}

static int
api_time(lua_State *L)
{
	long long t = kernel_walltime();

	if (t == 0)
		lua_pushnil(L);
	else
		lua_pushinteger(L, (lua_Integer)t);
	return 1;
}

/* sys.timer(ms): a receive right to a fresh port that gets exactly one
 * message (true) after roughly ms milliseconds. returns nil if the timer
 * table or the caller's rights table is full -- callers must handle that,
 * same as sys.newport().
 *
 * cancel by closing the right: the port dies, and expire_timers() reaps
 * the slot on its next pass without ever delivering.
 */
static int
api_timer(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer ms = luaL_checkinteger(L, 1);

	if (ms < 0)
		ms = 0;

	/* everything from here down is shared -- the timer table, the
	 * port table, this proc's rights -- and nothing in it raises:
	 * the failure paths all return 0 to lua rather than erroring.
	 * So one region covers the whole of it.
	 */
	ipclock_enter();

	/* capped like sys.newport: a timer is a port, and a loop asking
	 * for timers spends the table just as fast.
	 */
	struct kport *port = port_budget_left(p) ? port_new() : 0;

	if (!port) {
		ipclock_leave();
		return 0;
	}

	int h = right_new(p, port, 1);

	if (h < 0) {
		port->used = 0;
		ipclock_leave();
		return 0;
	}
	if (timer_arm(port, (unsigned long long)ms) < 0) {
		right_drop(p, right_slot(p, h));
		ipclock_leave();
		return 0;
	}
	ipclock_leave();
	lua_pushinteger(L, h);
	return 1;
}

static int
api_trace(lua_State *L)
{
	return trace_read_k(L, LUA_OK, 0);
}

static int
api_tracehist(lua_State *L)
{
	return tracehist_read_k(L, LUA_OK, 0);
}

static int
api_tryrecv(lua_State *L)
{
	struct kproc *p = self(L);
	lua_Integer h = luaL_checkinteger(L, 1);	/* raises; before */
	struct right *r;
	int empty = 0, rc = 0;

	r = right_get(p, h);
	if (r && r->recv) {
		struct kmsg *m = port_pop(r->port);

		empty = !m;
		if (m) {
			lua_pushboolean(L, 1);
			rc = msg_to_lua(L, p, m);
		}
	}

	if (!r || !r->recv)
		return luaL_error(L, "bad receive right");
	if (empty) {
		lua_pushboolean(L, 0);
		return 1;
	}
	/* the reason is carried out of the region rather than raised
	 * inside it: popfail raises, and a raise under the lock leaves it
	 * held.
	 */
	if (rc)
		return popfail(L, p, rc);
	return 2;
}

/* sys.uptime_ms(): milliseconds since boot, from the calibrated tsc.
 * prefer this to sys.ticks() for anything time-shaped -- ticks() is a
 * raw cycle counter whose rate differs per machine.
 */
static int
api_uptime_ms(lua_State *L)
{
	lua_pushinteger(L, (lua_Integer)uptime_ms());
	return 1;
}

static int
api_wchan(lua_State *L)
{
	struct kproc *p = self(L);

	if (!lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
	}
	return push_wchan(L, p);
}

static int
api_yield(lua_State *L)
{
	return lua_yield(L, 0);
}

static int
call_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	struct right *rr;

	(void)status;

	ipclock_enter();
	rr = right_get(p, (int)ctx);
	/* re-resolved rather than carried across the yield: a handle is an
	 * index into a table this proc can rearrange, and the right behind
	 * it may have moved. A miss is ordinary, not a bug -- the port can
	 * be torn down by the last other right going away while we parked.
	 */
	if (!rr || !rr->recv) {
		ipclock_leave();
		return luaL_error(L, "call: reply right went away");
	}
	if (!rr->port->head) {
		/* nobody left who could answer: our right is the last one, so
		 * the one that rode out with the request is gone. checked
		 * before parking again, since the wake that brought us here is
		 * usually the very drop being tested for (port_unref wakes
		 * receivers), and after the queue test so a reply that did
		 * arrive is delivered even when the server answered and died.
		 */
		if (sole_holder(p, rr->port)) {
			ipclock_leave();
			lua_pushnil(L);
			lua_pushliteral(L, "hungup");
			return 2;
		}
		/* woken with nothing for us -- another thread in this proc
		 * took the message first. park again. wake_receivers already
		 * dropped our waiter, so this adds a fresh one rather than
		 * leaking the old.
		 */
		if (!wait_add(p, rr->port, 0)) {
			ipclock_leave();
			return luaL_error(L, "out of waiters");
		}
		proc_block(p);
		ipclock_leave();
		return lua_yieldk(L, 0, ctx, call_k);
	}

	/* detach inside the region that established the queue is not
	 * empty, and deserialize outside it -- the message is ours alone
	 * once it is off the queue.
	 */
	struct kmsg *m = port_pop(rr->port);

	ipclock_leave();

	int rc = msg_to_lua(L, p, m);

	/* named out here, because popfail raises */
	if (rc)
		return popfail(L, p, rc);
	return 1;
}

/* One los.sys call, counted. A wrapper at registration rather than an
 * increment inside each api_ function, because registration is the one
 * door: a syscall added to kapi later is counted without anyone
 * remembering to.
 *
 * Counts only, no cycles: two clock reads per syscall would be real
 * overhead on the cheapest ones. The line profile already prices the
 * line a syscall sits on; what it cannot say is how many calls that
 * line made, and which.
 */
static int
counted(lua_State *L)
{
	struct kproc *p = self(L);
	lua_CFunction f = (lua_CFunction)lua_touserdata(L,
	    lua_upvalueindex(1));

	/* Registration makes the index constant; bound it anyway as the
	 * second lock, so strip_debug's removal of setupvalue is not the
	 * only thing keeping it inside kproc.calls[]. */
	lua_Integer idx = lua_tointeger(L, lua_upvalueindex(2));

	if (p && idx >= 0 && idx < NSYSCALL)
		p->calls[idx]++;
	return f(L);
}

static int
dump_writer(lua_State *L, const void *src, size_t sz, void *ud)
{
	struct dumpbuf *b = ud;

	(void)L;
	if (b->len + sz > b->cap) {
		size_t ncap = b->cap ? b->cap : 256;

		while (ncap < b->len + sz)
			ncap *= 2;
		char *nd = realloc(b->data, ncap);

		if (!nd)
			return 1;	/* nonzero aborts lua_dump */
		b->data = nd;
		b->cap = ncap;
	}
	memcpy(b->data + b->len, src, sz);
	b->len += sz;
	return 0;
}

/* the string hash seed every state is built with. See src/coreg.h.
 *
 * Computed on the first call and kept, which needs no lock: the boot
 * proc's state is made before smp_start_aps runs, so the boot cpu has
 * already been here by the time a second one exists.
 */
unsigned int
kernel_strseed(void)
{
	static unsigned int seed;

	if (seed == 0) {
		unsigned long long t = platform_ticks();

		/* never 0: that is the "not drawn yet" value above */
		seed = (unsigned int)(t ^ (t >> 32)) | 1u;
	}
	return seed;
}

static const luaL_Reg kapi[] = {
	{ "send", api_send },
	{ "call", api_call },
	{ "tryrecv", api_tryrecv },
	{ "block", api_block },
	{ "sendblock", api_sendblock },
	{ "alt", api_alt },
	{ "altpoll", api_altpoll },
	{ "anyready", api_anyready },
	{ "hangups", api_hangups },
	{ "yield", api_yield },
	{ "newport", api_newport },
	{ "owned", api_owned },
	{ "sendright", api_sendright },
	{ "spawn", api_spawn },
	{ "monitor", api_monitor },
	{ "close", api_close },
	{ "stats", api_stats },
	{ "reclaim", api_reclaim },
	{ "meminfo", api_meminfo },
	{ "battery", api_battery },
	{ "self", api_self },
	{ "procs", api_procs },
	{ "ports", api_ports },
	{ "granted", api_granted },
	{ "name", api_procname },
	{ "wchan", api_wchan },
	{ "stack", api_stack },
	{ "reap", api_reap },
	{ "atexit", api_atexit },
	{ "kill", api_kill },
	{ "set_trace", api_set_trace },
	{ "set_torture", api_set_torture },
	{ "trace", api_trace },
	{ "tracehist", api_tracehist },
	{ "syscalls", api_syscalls },
	{ "set_priority", api_set_priority },
	{ "priority", api_priority },
	{ "pidstat", api_pidstat },
	{ "ticks", api_ticks },
	{ "uptime_ms", api_uptime_ms },
	{ "log", api_log },
	{ "say", api_say },
	{ "logmirror", api_logmirror },
	{ "dmesg", api_dmesg },
	{ "loginfo", api_loginfo },
	{ "time", api_time },
	{ "settime", api_settime },
	{ "timer", api_timer },
	{ "setexit", api_setexit },
	{ "exit", api_exit },
	{ "hungup", api_hungup },
	{ NULL, NULL }
};

int
los_sys_open(lua_State *L)
{
	int n = 0;

	while (kapi[n].name)
		n++;
	/* a table that outgrew its counters would silently stop counting
	 * the tail of itself, so say so at the door instead.
	 */
	if (n > NSYSCALL)
		return luaL_error(L, "NSYSCALL too small for kapi (%d)", n);

	lua_createtable(L, 0, n);
	for (int i = 0; i < n; i++) {
		lua_pushlightuserdata(L, (void *)(intptr_t)kapi[i].func);
		lua_pushinteger(L, i);
		lua_pushcclosure(L, counted, 2);
		lua_setfield(L, -2, kapi[i].name);
	}

	/* SELF is the only well-known handle, and the only one that can
	 * be: it is how a proc receives at all, so there is nothing to
	 * bootstrap it from. Every other capability is granted at
	 * whatever slot right_new picked and looked up by name through
	 * sys.granted(). Those numbers are not an abi.
	 *
	 * Hardcoding one aliases: an ungranted capability leaves an empty
	 * slot, and the first-free search hands it to the next child.
	 */
	lua_pushinteger(L, 0);
	lua_setfield(L, -2, "SELF");

	/* the ceiling on one message, so a client splitting a large
	 * payload can ask instead of carrying its own copy of the number.
	 * It bounds the whole message, not just the payload string, so a
	 * caller splitting to exactly MAXMSG still fails on the table
	 * around it. Leave room.
	 */
	lua_pushinteger(L, MAXMSG);
	lua_setfield(L, -2, "MAXMSG");

	/* the revision this kernel was built from, which /VERSION.app and
	 * each filesystem image also carry. Answering from the binary
	 * rather than from a file is what lets a machine with nothing
	 * mounted still say what it is.
	 */
	lua_pushstring(L, LUAOS_REV);
	lua_setfield(L, -2, "rev");
	return 1;
}

/* may this proc act on that one? Holding a right to the target's self
 * port is the authority, and that port outlives the proc's own right to
 * it, so this answers for a corpse too.
 *
 * It gates what acts on a proc, not what reads one: sys.stack, sys.trace
 * and sys.pidstat stay ambient, because what they report is structure
 * rather than a proc's data. sys.set_trace is on this side because it
 * writes -- it reallocates a ring the target's own hook is filling.
 */
int
may_control(struct kproc *p, struct kproc *target)
{
	struct kport *port = proc_selfport(target);

	return port && proc_has_port(p, port);
}


/* push a popped message as one lua value, and dispose of it.
 *
 * returns nonzero having pushed nothing: -1 for a message this cannot
 * be, -2 for one it could not receive (a full rights table). A -2 loses
 * any rights the same message already installed.
 */
int
msg_to_lua(lua_State *L, struct kproc *p, struct kmsg *m)
{
	size_t off = 0;
	struct minted mt = { .n = 0 };
	/* the reason is kept as deserialize gave it, so popfail can tell a
	 * proc that ran out of rights from a message that would not decode.
	 */
	int rc = deserialize(L, m->data, m->len, &off, &m->bufs, p, 0, &mt);

	/* a message arrives whole or not at all. a partial walk has
	 * already minted rights the receiver was never told the numbers
	 * of, so it could not close them and they would be lost for its
	 * lifetime -- which a sender controls, and so could repeat.
	 */
	if (rc)
		minted_undo(p, &mt);

	/* receiver now holds its own refs (right_new); drop in-flight */
	msg_dispose(m);
	return rc;
}

/* a park must be issued from the state the kernel resumed. A yield
 * unwinds to the resumer of the state it fired in, so a block from a
 * coroutine below p->co lands in whoever resumed that, while this proc
 * is already marked BLOCKED and off the run queue -- surfacing later as
 * a protocol stalling somewhere else. Threads are safe: lib/thread
 * parks by yielding to thread.run, which blocks from the top.
 *
 * Checked at entry, not where the proc is descheduled: a call that
 * finds its message waiting would not park, but is still wrong.
 */
void
nopark(lua_State *L, struct kproc *p)
{
	if (L != p->co)
		luaL_error(L, "illegal parking: this coroutine is not the "
		    "one the kernel resumed, so a block here would never "
		    "reach it");
}

/* sys.owned(h): the right, as a to-be-closed value.
 *
 *	local guard <close> = sys.owned(sys.newport("srv.session"))
 *
 * Closed when the block ends, by return, break or error, so a port's
 * lifetime is a scope rather than a discipline. __close only, never
 * __gc: a right can travel in a message, and a finalizer runs at
 * whatever moment the collector picks. Here the moment is the point.
 */
static int
owned_close(lua_State *L)
{
	struct kproc *p = self(L);
	int *ud = luaL_checkudata(L, 1, "los.owned");
	struct right *r;

	if (*ud < 0)
		return 0;		/* closed already, or by hand */

	ipclock_enter();
	r = right_get(p, *ud);
	if (r && *ud != 0)
		right_drop(p, r);
	ipclock_leave();

	if (r && *ud != 0 && *ud < p->rhint)
		p->rhint = *ud;
	*ud = -1;
	return 0;
}

/* name a port_pop_to_lua failure: a local limit reached, or a message
 * that could not be decoded.
 */
int
popfail(lua_State *L, struct kproc *p, int rc)
{
	if (rc == -2) {
		if (p->bufdenied) {
			p->bufdenied = 0;
			return luaL_error(L, "no room for a transferred "
			    "buffer");
		}
		return luaL_error(L, "out of rights: %d of %d in use",
		    p->rhigh, MAXRIGHTS);
	}
	return luaL_error(L, "corrupt message");
}

/* which proc holds the receive right to a port, or -1. Not 0: pid 0 is
 * the console, a real proc that really does own ports, and using it as
 * the "nobody" sentinel reported every one of them as unowned.
 *
 * Answered by
 * looking rather than by a field on the port, because a receive right
 * moves: the holder is wherever it was last sent, and a field would be
 * one more thing to keep true on every transfer for the sake of a call
 * nobody makes in a hot loop.
 */
static int
port_owner(const struct kport *port)
{
	int id = -1;

	/* the proc table and every right table on it, so the wide lock
	 * rather than the one bucket covering this port.
	 */
	ipclock_enter();
	for (int i = 0; i < prochigh && id < 0; i++) {
		struct kproc *p = procv[i];

		if (!p || p->status == DEAD)
			continue;
		for (int h = 0; h < MAXRIGHTS; h++) {
			struct right *r = right_get(p, h);

			if (r && r->recv && r->port == port) {
				id = p->id;
				break;
			}
		}
	}
	ipclock_leave();
	return id;
}

/* `len`, if given, is filled with the serialized size of the message.
 * On SEND_FULL that is what a caller needs to wait for room: only the
 * kernel can know the figure, so lua never has to estimate one. See
 * api_sendblock for what asking for zero bytes costs.
 */
int
port_send_from_lua(lua_State *L, struct kproc *p, struct right *r, int idx,
    size_t *len)
{
	struct wbuf w = { 0 };
	int rc;

	wreserve(&w, sizehint(L, idx));
	if (serialize(L, idx, &w, p, 0)) {
		/* release refs taken for rights serialized before the
		 * failure point
		 */
		rc = SEND_UNSERIALIZABLE;
		goto discard;
	}

	/* what the queue will charge, which is what a waiter has to wait
	 * for room for: the message, plus the bytes it hands over.
	 */
	if (len)
		*len = w.len + msgbufs_bytes(&w.bufs);

	ipclock_enter_port(r->port);
	rc = port_push_owned(r->port, w.p, w.len, w.refs, w.refrecv, w.nrefs,
	    &w.bufs);
	ipclock_leave_port(r->port);

	switch (rc) {
	case 0:
		/* queued, so the bytes are the message's now. Until this
		 * point the sender still had them, which is what makes a
		 * refused send leave the sender whole.
		 */
		for (int i = 0; i < w.bufs.n; i++)
			luabuf_detach(L, w.bufown[i]);
		return SEND_OK;
	case -2:
		rc = SEND_FULL;
		break;
	case -3:
		rc = SEND_DEAD;
		break;
	default:
		rc = SEND_NOMEM;
		break;
	}
discard:
	/* outside the bucket, because releasing a reference needs all of
	 * them. Free of charge unless the message carried rights.
	 */
	if (w.nrefs) {
		ipclock_enter();
		release_inflight(w.refs, w.refrecv, w.nrefs);
		ipclock_leave();
	}
	free(w.p);
	return rc;
}

int
proc_hold(lua_State *L, int argn, struct kproc **out, lua_KContext ctx)
{
	struct kproc *me = self(L);
	struct kproc *p = me;

	if (!lua_isnoneornil(L, argn)) {
		p = find_proc_locked((int)luaL_checkinteger(L, argn));
		if (!p)
			return HOLD_GONE;
	}
	*out = p;
	if (p == me)
		return HOLD_SELF;	/* the one proc that cannot move */

	/* frozen on the first pass and left frozen across every yield, so
	 * there is no window in which it could be dispatched again
	 * between the wait and the read. ctx says it is already ours.
	 */
	if (ctx == 0) {
		if (proc_freeze(p))
			return HOLD_WAIT;
	} else if (proc_still_running(p)) {
		return HOLD_WAIT;
	}
	return HOLD_HELD;
}

int
push_wchan(lua_State *L, struct kproc *p)
{
	switch (p->status) {
	case DEAD:
		lua_pushliteral(L, "dead");
		return 1;
	case HATCHING:
		lua_pushliteral(L, "hatching");
		return 1;
	case BROKE:
		lua_pushliteral(L, "broke");
		return 1;
	case STOPPED:
		lua_pushliteral(L, "stopped");
		return 1;
	case READY:
		lua_pushliteral(L, "ready");
		return 1;
	case BLOCKED: {
		struct waiter *only = SLIST_FIRST(&p->waiters);

		if (only && !only->send && !SLIST_NEXT(only, pw)) {
			lua_pushfstring(L, "port#%d",
			    (int)only->port->idx);
			return 1;
		}
	}
		/* distinguished from a receive wait on purpose: "why is
		 * this proc stuck" has a different answer for a reader
		 * with no data and a writer with no room, and ps is where
		 * you go to find out.
		 */
		struct waiter *w = SLIST_FIRST(&p->waiters);

		if (w && w->send) {
			lua_pushfstring(L, "sendq#%d",
			    (int)w->port->idx);
			return 1;
		}
		if (w) {
			luaL_Buffer b;
			int first = 1;

			luaL_buffinit(L, &b);
			luaL_addstring(&b, "alt[");
			SLIST_FOREACH(w, &p->waiters, pw) {
				char tmp[16];

				snprintf(tmp, sizeof tmp, "%s%d",
				    first ? "" : ",",
				    (int)w->port->idx);
				first = 0;
				luaL_addstring(&b, tmp);
			}
			luaL_addstring(&b, "]");
			luaL_pushresult(&b);
			return 1;
		}
		lua_pushliteral(L, "blocked");
		return 1;
	}
	lua_pushliteral(L, "?");
	return 1;
}

struct kproc *
self(lua_State *L)
{
	return *(struct kproc **)lua_getextraspace(L);
}

static int
set_trace_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p = self(L);
	int arg = 1;
	lua_Integer n;

	(void)status;

	if (lua_gettop(L) > 1 || (lua_gettop(L) == 1 && lua_isnoneornil(L, 1)))
		arg = 2;
	if (arg == 2 && !lua_isnoneornil(L, 1)) {
		p = find_proc_locked((int)luaL_checkinteger(L, 1));
		if (!p)
			return luaL_error(L, "no such proc");
		/* the one call here that writes to another proc, so the
		 * one that takes a right to it. Reading does not: arming
		 * is what slows the target down, and what reallocates a
		 * ring its own hook is filling.
		 */
		if (p != self(L) && !may_control(self(L), p))
			return luaL_error(L, "no right to proc %d", p->id);
	}
	n = luaL_checkinteger(L, arg);
	if (n < 0)
		return luaL_error(L, "trace size must not be negative");
	if (n > TRACEMAX)
		n = TRACEMAX;
	if (!p->L)
		return luaL_error(L, "proc %d has no state", p->id);
	/* a trace has to be armed before the death it is meant to
	 * explain. arming a corpse can only ever produce an empty ring,
	 * which reads as "this proc ran no lines" rather than "you are
	 * too late", so it is refused. for a proc too short-lived to
	 * catch, spawn's opts.trace is the way in.
	 */
	if (p->status == BROKE && n > 0)
		return luaL_error(L,
		    "proc %d is broke; trace before it dies, or spawn "
		    "with opts.trace", p->id);

	/* held for the arm itself, and only for that: trace_arm frees a
	 * ring the target's line hook is writing into. Everything above
	 * that can raise has already run, so the freeze spans nothing that
	 * could jump past the thaw.
	 */
	if (p != self(L)) {
		if (ctx == 0) {
			if (proc_freeze(p))
				return lua_yieldk(L, 0, 1, set_trace_k);
		} else if (proc_still_running(p)) {
			return lua_yieldk(L, 0, 1, set_trace_k);
		}
	}

	int armed = trace_arm(p, (int)n);

	if (p != self(L))
		proc_thaw(p);
	if (armed != 0)
		return luaL_error(L, "out of memory");
	lua_pushboolean(L, 1);
	return 1;
}

/* is this proc the only holder of a right to `port`? That is our eof.
 * It counts every right the proc holds rather than testing nrights
 * against one, because a caller may hold several to one port -- a reply
 * port is a receive right to wait on plus a send right to publish -- and
 * a right it holds itself cannot answer it. sys.hungup must ask the same
 * question, or the two disagree about when a server has gone.
 */
int
sole_holder(struct kproc *p, struct kport *port)
{
	int mine = 0;

	for (int i = 0; i < p->rhigh; i++) {
		struct right *q = right_slot(p, i);

		if (q && q->used && q->port == port)
			mine++;
	}
	return port->nrights <= mine;
}

/* the walk, as a lua function so it can be called protected: it
 * allocates in the caller's state to build the result, so it can raise
 * on a caller at its memory limit -- and a raise that escaped would
 * leave the target frozen, which is a proc that never runs again.
 */
static int
stack_walk(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);

	/* every coroutine, not just p->co: a proc built on lib/thread
	 * keeps its threads as coroutines, and walking p->co alone reports
	 * the scheduler -- the same frames idle or deadlocked.
	 */
	debug_push_stacks(L, p->L, p->co);
	return 1;
}

static int
trace_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct ktrace *t;
	unsigned int n, start;

	t = p->trace;
	if (!t || !t->cap) {
		lua_newtable(L);
		return 1;
	}
	n = t->n < t->cap ? t->n : t->cap;
	start = t->n - n;

	lua_createtable(L, (int)n, 0);
	for (unsigned int i = 0; i < n; i++) {
		struct tracent *e = &t->ent[(start + i) % t->cap];

		lua_createtable(L, 0, 5);
		lua_pushstring(L, e->src < t->nname ? t->name[e->src] : "?");
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, e->line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, e->co);
		lua_setfield(L, -2, "thread");
		/* cycles this line cost, and cycles the proc was not running
		 * after it. See struct tracent on why both.
		 */
		lua_pushinteger(L, e->cpu);
		lua_setfield(L, -2, "cpu");
		lua_pushinteger(L, e->wall);
		lua_setfield(L, -2, "wall");
		lua_rawseti(L, -2, (int)i + 1);
	}
	return 1;
}

static int
tracehist_body(lua_State *L)
{
	struct kproc *p = lua_touserdata(L, 1);
	struct ktrace *t;
	struct histrow *row;
	int cap, nrow = 0, last = -1;
	unsigned int n, start, dropped = 0;

	t = p->trace;
	if (!t || !t->cap) {
		lua_newtable(L);
		return 1;
	}
	n = t->n < t->cap ? t->n : t->cap;
	start = t->n - n;

	/* Sized to the ring, so every distinct line gets a row. A fixed
	 * table cannot: aggregation meets keys in the order they occur, so
	 * one that fills stops admitting new lines -- and the ones it then
	 * fails to report are whichever appeared late, not the cold ones.
	 * A histogram that quietly does that looks like an answer.
	 */
	cap = (int)n;
	row = malloc((size_t)cap * sizeof *row);
	if (!row)
		return luaL_error(L, "tracehist: out of memory");

	for (unsigned int i = 0; i < n; i++) {
		struct tracent *e = &t->ent[(start + i) % t->cap];
		int j;

		/* consecutive entries are often the same line -- a loop, or
		 * a line that yields -- so try the last match first, the
		 * same trick the source interning uses one field over.
		 */
		if (last >= 0 && row[last].line == e->line &&
		    row[last].src == e->src) {
			j = last;
		} else {
			for (j = 0; j < nrow; j++)
				if (row[j].line == e->line &&
				    row[j].src == e->src)
					break;
		}
		if (j == nrow) {
			if (nrow >= cap) {
				dropped++;
				continue;
			}
			row[nrow].line = e->line;
			row[nrow].src = e->src;
			row[nrow].count = 0;
			row[nrow].cpu = 0;
			row[nrow].wall = 0;
			nrow++;
		}
		row[j].count++;
		row[j].cpu += e->cpu;
		row[j].wall += e->wall;
		last = j;
	}

	/* selection sort: a few hundred rows, once, in a debugging call.
	 * Anything cleverer would be optimizing the reader.
	 */
	for (int i = 0; i < nrow; i++) {
		int best = i;

		for (int j = i + 1; j < nrow; j++)
			if (row[j].cpu > row[best].cpu ||
			    (row[j].cpu == row[best].cpu &&
			     row[j].count > row[best].count))
				best = j;
		if (best != i) {
			struct histrow tmp = row[i];

			row[i] = row[best];
			row[best] = tmp;
		}
	}

	lua_createtable(L, nrow, 1);
	for (int i = 0; i < nrow; i++) {
		lua_createtable(L, 0, 5);
		lua_pushstring(L, row[i].src < t->nname ?
		    t->name[row[i].src] : "?");
		lua_setfield(L, -2, "source");
		lua_pushinteger(L, row[i].line);
		lua_setfield(L, -2, "line");
		lua_pushinteger(L, (lua_Integer)row[i].count);
		lua_setfield(L, -2, "count");
		lua_pushinteger(L, (lua_Integer)row[i].cpu);
		lua_setfield(L, -2, "cpu");
		lua_pushinteger(L, (lua_Integer)row[i].wall);
		lua_setfield(L, -2, "wall");
		lua_rawseti(L, -2, i + 1);
	}
	/* said rather than silently truncated: a histogram missing rows is
	 * a histogram whose percentages do not mean what they look like.
	 */
	lua_pushinteger(L, (lua_Integer)dropped);
	lua_setfield(L, -2, "dropped");
	free(row);
	return 1;
}

/* No static fallback table when that malloc fails: sys.tracehist is an
 * ordinary syscall, so two procs on two cpus can be inside it at once,
 * both writing one shared array. Raising rather than locking, because
 * the lock would have to span the table building below, which allocates
 * in the caller's state and can raise straight through the unlock.
 */
static int
tracehist_read_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, tracehist_read_k);
	case HOLD_SELF:
		lua_pushlightuserdata(L, p);
		lua_replace(L, 1);
		return tracehist_body(L);
	}

	lua_pushcfunction(L, tracehist_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

static int
trace_read_k(lua_State *L, int status, lua_KContext ctx)
{
	struct kproc *p;

	(void)status;
	switch (proc_hold(L, 1, &p, ctx)) {
	case HOLD_GONE:
		return luaL_error(L, "no such proc");
	case HOLD_WAIT:
		return lua_yieldk(L, 0, 1, trace_read_k);
	case HOLD_SELF:
		lua_pushlightuserdata(L, p);
		lua_replace(L, 1);
		return trace_body(L);
	}

	lua_pushcfunction(L, trace_body);
	lua_pushlightuserdata(L, p);

	int rc = lua_pcall(L, 1, 1, 0);

	proc_thaw(p);
	if (rc != LUA_OK)
		return lua_error(L);
	return 1;
}

