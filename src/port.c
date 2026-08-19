/* ports, rights, and message delivery. see docs/ipc.md, and
 * docs/locking.md for the lock over all of it.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <sys/queue.h>

#include "lua.h"
#include "lock.h"
#include "cpu.h"
#include "kernel.h"
#include "kproc.h"
#include "port.h"
#include "ksched.h"
#include "platform.h"

/* the lock over everything shared between procs: the port and proc
 * index tables, every port's messages and waiters, the refcounts that
 * decide when a port dies, and the rights a sender mints into a
 * receiver's table. Buckets hashed on port index, taken caller-holds.
 * Read docs/locking.md before narrowing a caller to one bucket.
 */
#define NIPCLOCK 8

struct ipcbucket {
	struct lock lk;
	/* atomic because ipclock_enter_one's fast path reads it without
	 * the lock. Relaxed is enough: a cpu is the only writer of its
	 * own value, so a racing read can be stale but never wrongly
	 * equal to me. depth is owner-only, so it needs none of that.
	 */
	_Atomic(struct cpu *) owner;
	int depth;

	/* how long it is held, summed. lock.h counts the waiting; these
	 * two together say whether splitting further would buy
	 * anything. Owner-only, like depth.
	 */
	/* held is written by the bucket.s holder and read by sys.stats
	 * from another cpu; t0 never leaves the holder. */
	atomic_ullong held;
	unsigned long long t0;
};

/* zero is the initial state of every field, LOCK_INIT included, so
 * there is nothing to write here.
 */
static struct ipcbucket ipcbuckets[NIPCLOCK];

/* recursive by need: a receive holds the lock across a deserialize,
 * which allocates, which can run a __gc handler that closes a handle.
 *
 * Pitfall: a bucket whose owner is set but whose leave is missed is
 * never released, and every later acquire on that cpu takes the depth
 * fast path and succeeds. The kernel runs unlocked and the whole suite
 * passes. Trust kernel_run's no-bucket-held assertion, not the tests.
 */

struct kport *portv[MAXPORTS];
/* one past the highest slot ever used. Atomic because sys.ports and
 * sys.stats bound their walks with it holding no bucket, where port_new
 * raises it under bucket zero. Release/acquire, so a slot published
 * under it is visible to a reader that sees the higher bound.
 */
atomic_int porthigh;
/* stamped into every port so a slot can be told from the port in it;
 * see kport.gen. 64-bit and incremented once per port, so it does not
 * wrap in any run this machine could have.
 */
static unsigned long long portgen;

/* bumped whenever a port loses a reference, which is the only way
 * sys.hungup's answer can change. see api_hangups.
 */
static unsigned long long hangup_gen;

/* the high water over every proc's handle table, for sys.stats. Not
 * covered by any one bucket: right_new holds only the bucket of the
 * port it mints, and two cpus minting on different ports both raise it.
 */
static atomic_int rights_high;

/* how the claim goes, reported through sys.stats().lock.ipc. Losing
 * counts the times two ports reached one alt-blocked proc at once, so
 * it says how much of an alt set is live at the same moment.
 *
 * It is also the only evidence the losing branch runs at all: it is
 * reachable on more than one cpu and never on one, so a suite that
 * exercises it by accident stops the moment scheduling shifts. A test
 * asserts this counter is nonzero for that reason.
 */
static atomic_ullong claim_won, claim_lost;

void
msgbufs_free(struct msgbufs *b)
{
	for (int i = 0; i < b->n; i++)
		if (b->p[i])
			platform_chunk_free(b->p[i], b->len[i]);
	b->n = 0;
}

size_t
msgbufs_bytes(const struct msgbufs *b)
{
	size_t t = 0;

	for (int i = 0; i < b->n; i++)
		t += b->len[i];
	return t;
}

/* which bucket covers a port. The index is dense from zero and ports
 * are handed out in order, so the low bits spread as well as any
 * mixing would and cost nothing.
 */
static struct ipcbucket *
ipcbucket_of(const struct kport *p)
{
	return &ipcbuckets[p->idx & (NIPCLOCK - 1)];
}

/* does this cpu hold this bucket. Not lock.h's holding(), which answers
 * for the machine: under smp another cpu holding a bucket is ordinary
 * and says nothing about whether this one may touch the ports under it.
 */
static int
ipcheld_one(struct ipcbucket *b)
{
	return atomic_load_explicit(&b->owner, memory_order_relaxed) ==
	    cpu_self();
}

/* does this cpu hold every bucket, which is what the wide form gives
 * and what an assertion naming no port has to demand.
 */
int
ipcheld(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		if (!ipcheld_one(&ipcbuckets[i]))
			return 0;
	return 1;
}

/* any bucket at all. The weakest of the three, for a helper that needs
 * its caller to be inside an ipc region rather than to cover a named
 * port -- proc_block, which records a decision a bucket held still.
 */
int
ipcheld_any(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		if (ipcheld_one(&ipcbuckets[i]))
			return 1;
	return 0;
}

int
ipcheld_one_port(struct kport *p)
{
	return ipcheld_one(ipcbucket_of(p));
}

static void
ipclock_enter_one(struct ipcbucket *b)
{
	struct cpu *me = cpu_self();

	if (atomic_load_explicit(&b->owner, memory_order_relaxed) == me) {
		b->depth++;
		return;
	}
	lock(&b->lk);
	atomic_store_explicit(&b->owner, me, memory_order_relaxed);
	b->depth = 1;
	b->t0 = machine_cycles();
}

static void
ipclock_leave_one(struct ipcbucket *b)
{
	if (--b->depth > 0)
		return;
	lock_bump(&b->held, machine_cycles() - b->t0);
	atomic_store_explicit(&b->owner, 0, memory_order_relaxed);
	unlock(&b->lk);
}

/* the one bucket covering p. See the obligations listed over the
 * bucket array: no other port, and no lua allocation.
 */
void
ipclock_enter_port(struct kport *p)
{
	ipclock_enter_one(ipcbucket_of(p));
}

void
ipclock_leave_port(struct kport *p)
{
	ipclock_leave_one(ipcbucket_of(p));
}

/* every bucket, ascending, which is the order two locks of one class
 * are taken in everywhere. Release order is free.
 */
void
ipclock_enter(void)
{
	for (unsigned i = 0; i < NIPCLOCK; i++)
		ipclock_enter_one(&ipcbuckets[i]);
}

void
ipclock_leave(void)
{
	for (unsigned i = NIPCLOCK; i-- > 0; )
		ipclock_leave_one(&ipcbuckets[i]);
}

/* release a right that was serialized into a message but never
 * delivered (send failed, or the queue was flushed). a receive right in
 * flight was counted in nrecv when it was serialized, so it has to be
 * uncounted here -- and BEFORE port_unref, which decides port death by
 * looking at nrecv.
 */
void
release_inflight(const unsigned short *refs, const unsigned char *refrecv,
    int n)
{
	/* caller holds ipclock, unless there is nothing to release. The
	 * empty case is the common one: a message carrying no rights
	 * names no port, so this touches nothing and may be called from
	 * anywhere -- which is what lets an ordinary message be disposed
	 * of without leaving one bucket to take all eight.
	 */
	if (n == 0)
		return;
	IPC_ASSERT_LOCKED();
	for (int i = 0; i < n; i++) {
		struct kport *port = portv[refs[i]];

		if (!port)
			continue;

		if (refrecv && refrecv[i])
			port->nrecv--;
		port_unref(port);
	}
}

struct kport *
port_new(void)
{
	for (int i = 0; i < MAXPORTS; i++)
		if (!portv[i]) {
			struct kport *port = malloc(sizeof *port);

			if (!port)
				return 0;
			memset(port, 0, sizeof *port);
			port->idx = (unsigned short)i;
			port->gen = ++portgen;
			port->used = 1;
			TAILQ_INIT(&port->waiters);
			portv[i] = port;
			if (i >= atomic_load_explicit(&porthigh,
			    memory_order_relaxed))
				atomic_store_explicit(&porthigh, i + 1,
				    memory_order_release);
			return port;
		}
	return 0;
}

/* has this proc room for another port?
 *
 * asked before the table is searched, so a proc over its limit costs
 * nothing to refuse and cannot take the last free slot from one still
 * under. the count itself is kept by right_new and right_drop, which is
 * where a receive right is gained and lost.
 */
int
port_budget_left(struct kproc *p)
{
	return !p->port_limit || p->nports < p->port_limit;
}

/* the port behind this proc's handle 0, or null if it has gone.
 *
 * see kproc.selfidx: the pair is checked rather than a pointer chased,
 * so a portv slot reused since says no instead of yes about a stranger.
 */
struct kport *
proc_selfport(struct kproc *p)
{
	if (!p->selfgen)
		return 0;

	struct kport *port = portv[p->selfidx];

	if (!port || port->gen != p->selfgen)
		return 0;
	return port;
}

/* free one message: the in-flight right refs it carries, and any
 * transferred buffer nobody took.
 */
void
msg_free(struct kmsg *m)
{
	release_inflight(m->refs, m->refrecv, m->nrefs);
	msgbufs_free(&m->bufs);
	free(m->data);
	free(m);
}

void
port_flush(struct kport *port)
{
	struct kmsg *m = atomic_load_explicit(&port->head, memory_order_relaxed);

	atomic_store_explicit(&port->head, 0, memory_order_relaxed);
	port->tail = 0;
	KSTAT_SET(port->qbytes, 0);
	while (m) {
		struct kmsg *next = m->next;

		msg_free(m);
		m = next;
	}
}

/* drop one reference; the last ref frees the port. dropping the last
 * *receive* right marks the port dead and flushes the queue -- nobody
 * can ever take those messages. flushing may recursively unref other
 * ports whose only rights were in the flushed messages.
 */
void
port_unref(struct kport *port)
{
	/* caller holds ipclock.
	 * CONTEXT: expire_timers, port_new, reap_dead_timers,
	 * release_inflight, right_drop.
	 */
	IPC_ASSERT_LOCKED();
	if (--port->nrights <= 0) {
		/* flush first: it can unref other ports, and one of those
		 * could be this one's last reference from a queued message
		 */
		port_flush(port);
		portv[port->idx] = 0;
		free(port);
		return;
	}
	if (port->nrecv == 0 && !port->dead) {
		port->dead = 1;
		port_flush(port);
	}
	/* a dropped reference can make sys.hungup() true for whoever is
	 * left, so anyone parked on this port has to re-check. without this
	 * a pipe reader blocked for data would sleep through its writer's
	 * exit and never see eof.
	 */
	hangup_gen++;
	wake_receivers(port);
	/* the same for writers: a reader going away means a full port will
	 * never drain, so anyone parked for room has to wake and learn
	 * from its next send that the port is dead. exact twin of the eof
	 * case above, and without it a blocked writer outlives its reader
	 * forever.
	 */
	wake_senders(port);
}

/* the slot a handle names, or null if it is out of range or lives in an
 * overflow array this proc has never needed. never allocates: it is on
 * every send and receive, with a handle the caller may have made up.
 */
struct right *
right_slot(struct kproc *p, int h)
{
	if (h < 0 || h >= MAXRIGHTS)
		return 0;
	if (h < NRIGHTS_INLINE)
		return &p->rights[h];
	if (!p->xrights)
		return 0;
	return &p->xrights[h - NRIGHTS_INLINE];
}

static struct right *
right_slot_grow(struct kproc *p, int h)
{
	if (h < 0 || h >= MAXRIGHTS)
		return 0;
	if (h < NRIGHTS_INLINE)
		return &p->rights[h];
	if (!p->xrights) {
		size_t n = MAXRIGHTS - NRIGHTS_INLINE;

		p->xrights = malloc(n * sizeof *p->xrights);
		if (!p->xrights)
			return 0;
		memset(p->xrights, 0, n * sizeof *p->xrights);
	}
	return &p->xrights[h - NRIGHTS_INLINE];
}

int
right_new(struct kproc *p, struct kport *port, int recv)
{
	/* The one helper here that needs no lock. p's right table belongs
	 * to p, and only p runs at a time; port->nrights is atomic, and
	 * taking a reference destroys nothing, because the caller already
	 * holds one. That is what lets deserialize run outside every
	 * bucket, which it must: building lua values allocates.
	 *
	 * Start where a free slot was last seen, or a proc holding many
	 * rights rescans all of them for each new one.
	 */
	for (int i = p->rhint; i < MAXRIGHTS; i++) {
		struct right *r = right_slot_grow(p, i);

		if (!r)
			return -1;
		if (!r->used) {
			if (i + 1 > KSTAT_GET(rights_high))
				KSTAT_SET(rights_high, i + 1);
			r->used = 1;
			r->port = port;
			r->recv = recv;
			port->nrights++;
			if (recv) {
				port->nrecv++;
				/* what this proc is charged for; see
				 * kproc.nports
				 */
				if (++p->nports > p->nports_peak)
					p->nports_peak = p->nports;
			}
			p->rhint = i + 1;
			if (i + 1 > p->rhigh)
				p->rhigh = i + 1;
			return i;
		}
	}
	return -1;
}

void
right_drop(struct kproc *p, struct right *r)
{
	/* caller holds ipclock. */
	IPC_ASSERT_LOCKED();
	struct kport *port = r->port;

	r->used = 0;
	if (r->recv) {
		port->nrecv--;
		if (p->nports > 0)
			p->nports--;
	}
	port_unref(port);
}

/* grant a named capability: take a right the ordinary way and record
 * its name in the proc's grant list, so lua can find the handle through
 * sys.granted(). A null port is a no-op, which is the "not this boot"
 * case. The list has no ceiling: a fixed array silently drops grants
 * past its size, and a missing grant reads as a broken device.
 */
void
grant_named(struct kproc *p, const char *name, struct kport *port, int recv)
{
	if (!port)
		return;

	int h = right_new(p, port, recv);

	if (h < 0)
		return;

	struct grant *g = malloc(sizeof *g);

	if (!g) {
		/* the right was taken; drop it rather than leave an anonymous
		 * handle behind on an allocation that failed.
		 */
		struct right *r = right_slot(p, h);

		if (r)
			right_drop(p, r);
		return;
	}
	g->name = name;
	g->handle = h;
	SLIST_INSERT_HEAD(&p->grants, g, e);
}

struct right *
right_get(struct kproc *p, lua_Integer h)
{
	struct right *r = right_slot(p, (int)h);

	if (!r || !r->used)
		return 0;
	return r;
}

/* attach p to port's wait list. returns 0 only if an allocation failed,
 * which the caller must report rather than silently not waiting -- a proc
 * that believes it is blocked but is on no list never wakes.
 */
int
wait_add(struct kproc *p, struct kport *port, int send)
{
	/* caller holds the bucket covering `port`.
	 * CONTEXT: the five blocking calls, all of which hold it
	 * across the test that decided to sleep.
	 *
	 * Per-port rather than every bucket, because that is all this
	 * touches: one port's waiter list, and p's own list, which
	 * belongs to the running proc. alt names several ports but one
	 * per call, so this is the right demand there too.
	 */
	IPC_ASSERT_PORT(port);
	struct waiter *w;

	if (!p->w0used) {
		p->w0used = 1;
		w = &p->w0;
	} else {
		w = malloc(sizeof *w);
		if (!w)
			return 0;
	}
	w->p = p;
	w->port = port;
	w->send = send;
	w->onport = 1;
	TAILQ_INSERT_TAIL(&port->waiters, w, pq);
	SLIST_INSERT_HEAD(&p->waiters, w, pw);
	return 1;
}

/* drop every wait this proc holds. called on death and by alt before it
 * builds a new set, so it has to be safe to call when the list is
 * already empty.
 *
 * This is the wide operation: it reaches every port the proc waits on,
 * so it demands every bucket. wait_reap is the narrow form and is what
 * the wake path uses.
 */
void
wait_clear(struct kproc *p)
{
	/* caller holds ipclock.
	 * CONTEXT: alt, proc_detach.
	 */
	IPC_ASSERT_LOCKED();
	while (!SLIST_EMPTY(&p->waiters)) {
		struct waiter *w = SLIST_FIRST(&p->waiters);

		SLIST_REMOVE_HEAD(&p->waiters, pw);
		if (w->onport)
			TAILQ_REMOVE(&w->port->waiters, w, pq);
		if (w == &p->w0)
			p->w0used = 0;
		else
			free(w);
	}
}

/* collect the waits left over from the last block, on the proc's own cpu
 * and just before it is resumed. The waker holds one port's bucket, so
 * it unlinks only the entry it woke on; a proc in an alt is on several,
 * and collects the rest here, one bucket at a time. Linux's poll splits
 * pollwake and poll_freewait the same way round.
 *
 * Also where `woken` is cleared, which re-arms the proc to be claimed
 * the next time it blocks. Nothing can claim it in between, because a
 * running proc is not BLOCKED.
 */
void
wait_reap(struct kproc *p)
{
	while (!SLIST_EMPTY(&p->waiters)) {
		struct waiter *w = SLIST_FIRST(&p->waiters);

		SLIST_REMOVE_HEAD(&p->waiters, pw);
		if (w->onport) {
			ipclock_enter_port(w->port);
			/* re-read under the bucket: a waker may have
			 * unlinked it between the test and the lock.
			 */
			if (w->onport) {
				TAILQ_REMOVE(&w->port->waiters, w, pq);
				w->onport = 0;
			}
			ipclock_leave_port(w->port);
		}
		if (w == &p->w0)
			p->w0used = 0;
		else
			free(w);
	}
	atomic_store_explicit(&p->woken, 0, memory_order_relaxed);
}

/* take the right to wake this proc, or find that another port already
 * has. See kproc.woken.
 */
static int
wake_claim(struct kproc *p)
{
	int expect = 0;

	if (atomic_compare_exchange_strong_explicit(&p->woken, &expect, 1,
	    memory_order_acq_rel, memory_order_relaxed)) {
		atomic_fetch_add_explicit(&claim_won, 1, memory_order_relaxed);
		return 1;
	}
	atomic_fetch_add_explicit(&claim_lost, 1, memory_order_relaxed);
	return 0;
}

void
wake_receivers(struct kport *port)
{
	/* caller holds the bucket covering `port`. Touches another proc's
	 * run queue and this port's waiter list, but no other port's,
	 * which is what lets a sender hold one bucket.
	 */
	IPC_ASSERT_PORT(port);
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (w->send || KSTAT_GET(p->status) != BLOCKED)
			continue;
		if (!wake_claim(p))
			continue;	/* another port got there first */
		TAILQ_REMOVE(&port->waiters, w, pq);
		w->onport = 0;
		make_ready(p);
	}
}

/* the mirror of wake_receivers: anyone parked for room on this port.
 * Draining a message is the ordinary wakeup; a port dying is the other,
 * and without it a writer blocked on a full port whose reader vanished
 * sleeps forever. A spurious wake is harmless, since sys.sendblock only
 * promises the port might have room and every caller loops.
 */
void
wake_senders(struct kport *port)
{
	/* caller holds the bucket covering `port`. */
	IPC_ASSERT_PORT(port);
	struct waiter *w, *n;

	TAILQ_FOREACH_SAFE(w, &port->waiters, pq, n) {
		struct kproc *p = w->p;

		if (!w->send || KSTAT_GET(p->status) != BLOCKED)
			continue;
		if (!wake_claim(p))
			continue;
		TAILQ_REMOVE(&port->waiters, w, pq);
		w->onport = 0;
		make_ready(p);
	}
}

/* queue a message, taking ownership of `data` only when it returns 0. A
 * dead port drops it silently: the sender learns from a monitor, not
 * from the send. refs/nrefs are in-flight right refs, and may be null.
 *
 * On any refusal the caller still owns the buffer and the refs, and
 * must free the one and release the other. That is deliberate: this
 * runs under one bucket, and releasing a reference can flush a queue,
 * which reaches ports under other buckets and so demands all of them.
 * A narrow region cannot widen, so disposal waits for the caller.
 */
int
port_push_owned(struct kport *port, unsigned char *data, size_t len,
    const unsigned short *refs, const unsigned char *refrecv, int nrefs,
    const struct msgbufs *bufs)
{
	/* caller holds the bucket covering `port`. */
	IPC_ASSERT_PORT(port);
	if (port->dead) {
		port->ndrop_dead++;
		KSTAT_ADD(cpu_self()->ndrop_dead, 1);
		return -3;
	}

	/* transferred bytes count against the queue too. They are not in
	 * the message, so without this a sender could park megabytes on a
	 * queue nobody drains and MAXQUEUE would read as empty.
	 */
	size_t cost = len + (bufs ? msgbufs_bytes(bufs) : 0);

	if (KSTAT_GET(port->qbytes) + cost > MAXQUEUE) {
		port->ndrop_full++;
		KSTAT_ADD(cpu_self()->ndrop_full, 1);
		return -2;		/* full, distinct from out of memory */
	}

	struct kmsg *m = malloc(sizeof *m);

	if (!m)
		return -1;
	m->next = 0;
	m->len = len;
	m->qcost = cost;
	m->data = data;
	m->nrefs = nrefs;
	if (bufs)
		m->bufs = *bufs;
	else
		m->bufs.n = 0;
	for (int i = 0; i < nrefs; i++) {
		m->refs[i] = refs[i];
		m->refrecv[i] = refrecv ? refrecv[i] : 0;
	}
	if (port->tail)
		port->tail->next = m;
	else
		atomic_store_explicit(&port->head, m, memory_order_relaxed);
	port->tail = m;
	KSTAT_ADD(port->qbytes, cost);
	if (KSTAT_GET(port->qbytes) > KSTAT_GET(port->qpeak))
		KSTAT_SET(port->qpeak, KSTAT_GET(port->qbytes));
	KSTAT_ADD(port->nsent, 1);
	wake_receivers(port);
	return 0;
}

/* copying form, for callers whose bytes are on the stack or in a string
 * literal -- the device pumps and the timer tick. they push a handful of
 * bytes, so the copy is not worth avoiding.
 */
int
port_push(struct kport *port, const unsigned char *data, size_t len,
    const unsigned short *refs, int nrefs)
{
	/* caller holds ipclock.
	 * CONTEXT: any outer ipc entry point.
	 */
	IPC_ASSERT_LOCKED();
	unsigned char *copy = malloc(len);

	if (!copy) {
		release_inflight(refs, 0, nrefs);
		return -1;
	}
	memcpy(copy, data, len);

	int rc = port_push_owned(port, copy, len, refs, 0, nrefs, 0);

	if (rc) {
		release_inflight(refs, 0, nrefs);
		free(copy);
	}
	/* a dead port is not this caller's failure -- see the erlang
	 * note above -- so it reads as success, which is what the
	 * refusal code used to be folded into.
	 */
	return rc == -3 ? 0 : rc;
}

/* take the head message off `port`, or null if there is none.
 *
 * The mirror of port_send_from_lua's split, and the same reasoning
 * backwards: detaching the message from the queue is the part that
 * needs the bucket, and turning it into lua values is the part that
 * must not have it. Once detached the message is the caller's alone --
 * no other cpu can reach it -- and the in-flight references it carries
 * keep every port it names alive until msg_dispose.
 */
struct kmsg *
port_pop(struct kport *port)
{
	struct kmsg *m;

	ipclock_enter_port(port);
	m = atomic_load_explicit(&port->head, memory_order_relaxed);
	if (m) {
		atomic_store_explicit(&port->head, m->next,
		    memory_order_relaxed);
		if (!m->next)
			port->tail = 0;
		KSTAT_SET(port->qbytes, KSTAT_GET(port->qbytes) - m->qcost);
		/* room freed: this is the ordinary backpressure wakeup */
		wake_senders(port);
	}
	ipclock_leave_port(port);
	return m;
}

/* finish with a popped message. Wide only when it carries rights,
 * which is what dropping their in-flight references demands.
 */
void
msg_dispose(struct kmsg *m)
{
	if (m->nrefs) {
		ipclock_enter();
		msg_free(m);
		ipclock_leave();
	} else {
		msg_free(m);
	}
}

/* release_inflight for the one caller that is not already holding the
 * lock. api_spawn interleaves five of these with luaL_error, and a
 * region wide enough to cover them all would have to survive a
 * longjmp; one acquisition per call cannot.
 */
void
release_inflight_locked(const unsigned short *refs, const unsigned char *refrecv,
    int nrefs)
{
	ipclock_enter();
	release_inflight(refs, refrecv, nrefs);
	ipclock_leave();
}

/* disk gates write/append only (read is ambient, see stdio.c's
 * fopen): does whoever is currently resumed hold any right to
 * diskport? used from fopen, which has no lua_State at all --
 * liolib.c's io.open calls it as plain C, so cpu_self()->current is
 * the only way to learn who's asking.
 */
int
proc_has_port(struct kproc *p, struct kport *port)
{
	if (!p || !port)
		return 0;
	for (int i = 0; i < MAXRIGHTS; i++) {
		struct right *r = right_slot(p, i);

		if (r && r->used && r->port == port)
			return 1;
	}
	return 0;
}


unsigned long long
port_hangups(void)
{
	return hangup_gen;
}

/* the eight buckets summed, so a caller sees one lock's worth of
 * numbers. Contention rate alone misleads, since the wide form takes
 * every bucket and so moves the denominator with the design.
 */
void
ipclock_stats(unsigned long long *nlock, unsigned long long *ncontend,
    unsigned long long *spin, unsigned long long *held)
{
	*nlock = *ncontend = *spin = *held = 0;
	for (unsigned i = 0; i < NIPCLOCK; i++) {
		*nlock += atomic_load_explicit(&ipcbuckets[i].lk.nlock,
		    memory_order_relaxed);
		*ncontend += atomic_load_explicit(&ipcbuckets[i].lk.ncontend,
		    memory_order_relaxed);
		*spin += atomic_load_explicit(&ipcbuckets[i].lk.spin,
		    memory_order_relaxed);
		*held += atomic_load_explicit(&ipcbuckets[i].held,
		    memory_order_relaxed);
	}
}

int
port_rights_high(void)
{
	return KSTAT_GET(rights_high);
}

unsigned long long
port_claims(int won)
{
	return won ? claim_won : claim_lost;
}
