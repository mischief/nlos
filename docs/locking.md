# Locking

The rules a reader cannot derive from any one function, because they
are properties of how the locks meet each other and how they meet Lua.

`src/lock.h` holds the primitive and the lock order. This file holds
the ipc layer, which is where the difficulty is.

## The locks

    ipclock[8]   the ipc layer: ports, the port table, waiter lists
    schedlock    the run queues, p->current, p->frozen, p->oncpu
    pmm          the physical allocator

Taken left to right, released in any order. `pmm` is last because it is
a leaf: nothing is acquired while holding it.

The ipc lock is an array of eight, hashed on `port->idx`. Buckets
rather than a lock per port because buckets are static. A per-port lock
raises two questions this arrangement never asks: what its lifetime is
against the port's, and how it orders against the refcount that decides
that lifetime. Linux hashes futexes onto a fixed bucket array for the
same reason.

## Wide and narrow

    ipclock_enter()        every bucket, ascending
    ipclock_enter_port(p)  the one bucket covering p

A caller that names one port takes one bucket. A caller that walks the
port table, or that can reach a port it cannot name in advance, takes
all of them. Wide excludes narrow, because wide holds every bucket a
narrow caller could want.

**A narrow region may never widen.** It holds bucket *k* and the wide
form starts at bucket 0, so a narrow caller asking for the wide lock
deadlocks against anyone going the other way. Everything a narrow
region needs has to be either narrow itself or moved outside.

Two things are wide and are reached from the hot paths, so both were
moved outside rather than made narrow:

- `port_unref`, because dropping the last reference flushes the queue,
  and the messages in it hold references to other ports.
- `release_inflight`, for the same reason one level up.

## An allocation cannot run Lua

This was a rule to obey. It is now a property of the build, and the
difference matters: a rule is something a reader has to know and
nothing checks.

The hazard it addressed: a Lua allocation can run the collector, the
collector runs a `__gc` handler, and a `__gc` handler is arbitrary Lua.
Clunking a handle is what those handlers are *for*, so it comes back
through `api_close` -> `right_drop` -> `port_unref` on some other port
-- a second bucket, chosen by a hash, with no order to it.

`proc_new` calls `lua_gc(L, LUA_GCSTOP)`. With `GCSTPUSR` set,
`luaC_condGC` never steps, so no allocation anywhere can reach a
finalizer. `gc_step` advances the collector instead, from two places
that hold nothing: `dispatch_lap` after `run_proc` returns, and the
count hook between two VM instructions.

Two collections still happen without being asked, and neither can run
a finalizer where it would be unsafe. An allocation failure collects
and retries, because `cantryagain` consults `gcstopem` and not
`gcstp`; it runs in emergency mode, which sets `gcemergency`, and
every finalizer path tests that. And `lua_close` runs the pending
finalizers directly through `GCTM`, which is how a dying proc's
handles get clunked -- `proc_freestate` is called with no bucket held,
deliberately.

The allocating halves of the ipc calls still live outside the lock.
That is no longer required for correctness, but it is where the
contention went, so it stays:

    send     serialize        (no lock; mints in-flight references)
             port_push_owned  (one bucket; queue insert and wakeup)
             release/free     (wide, and only if it carried rights)

    receive  port_pop         (one bucket; detach and wake senders)
             deserialize      (no lock)
             msg_dispose      (wide, and only if it carried rights)

Once a message is off the queue it is the receiver's alone -- no other
cpu can reach it -- and the in-flight references it carries keep every
port it names alive until it is disposed of.

`port_push_owned` therefore does not dispose of what it refuses. The
caller still owns the buffer and the references on every refusal path
and cleans up after leaving the bucket. This is the awkward half of the
contract and it is deliberate.

### Why the references can be taken unlocked

`nrights` and `nrecv` are atomic. Taking a reference cannot destroy
anything, because whoever increments already holds one, so the count
was not zero and cannot reach zero underneath. Dropping one can, so
`port_unref` stays wide.

That asymmetry is what lets `serialize` and `right_new` run with
nothing held.

## The proc table

`procv`, `prochigh`, `nlive` and the pid counter are under the wide ipc
lock. Not a lock of their own: `proc_detach` reaches `find_proc` with
every bucket held, so a second lock would have to be ordered against
this one, and one lock is one order.

Every walk of the array takes the wide form. `proc_new` claims a slot
by wiping it, so a walk without the lock reads a proc that is halfway
between its last occupant and its next -- `sys.procs`, `sys.stats` and
`sys.meminfo` all did.

`find_proc` asserts the lock and `find_proc_locked` takes it. The
divide is by caller: the kernel's own spawn path and `proc_detach` are
already holding it, and a `sys.*` call naming another proc arrives with
nothing.

Two things the lock does not do.

It does not pin what a walk carries away. The pointer stays a pointer
-- a `struct kproc` is recycled in place, never freed -- but the proc
under it can die and be reborn as another once the lock is dropped.
Every caller today is either the proc itself or holds a right to the
target, which is what keeps this theoretical.

And `dbg_sweep` reads `procv[i]` without it, deliberately: it runs on
every lap of every cpu and the wide lock to find nothing is what the
ordinary machine would pay. `proc_new` zeroes a slot before publishing
it so that read sees a pointer or null, and the sweep re-reads under
the lock before acting.

## Waking

A waker holds one port's bucket. A proc in an `alt` waits on several
ports at once. So the waker must not touch the waiter's other lists,
and the old `wait_clear(p)` -- drop every wait this proc holds -- did
exactly that.

The split:

- the waker unlinks the entry on **its own port only**, and claims the
  proc with a compare-exchange on `kproc.woken`. A loser leaves the
  proc entirely alone.
- the woken proc collects its own leftovers in `wait_reap`, called from
  `run_proc` before it is resumed, taking one port's bucket at a time.

Go's runtime settles the same race with `g.selectDone` in
`waitq.dequeue`, and Linux splits `pollwake` from `poll_freewait` the
same way. Because only one lock is ever held on either side, there is
no order between ports to violate.

`woken` is cleared by `wait_reap`, which is what re-arms the proc for
the next block. Nothing can claim it in between: a running proc is not
`BLOCKED`.

## The assertions

Three, and a helper should make the weakest one it honestly can. The
weaker the demand, the more of the call graph can eventually be
narrowed.

    IPC_ASSERT_PORT(p)   the bucket covering p
    IPC_ASSERT_ANY()     some bucket -- the caller is inside a region
    IPC_ASSERT_LOCKED()  every bucket

They answer "held by this cpu", not `lock.h`'s `holding()`, which
answers for the machine. Under smp another cpu holding a bucket is the
ordinary case and says nothing.

They are live on every platform, not only where `NCPU > 1`: the owner
is recorded even on a uniprocessor, so efi, aarch64 and riscv64 check
the same contracts. A caller that forgot is a bug on one cpu too --
just one that cannot yet bite.

They are also the thing that reports a narrowing done wrong. Two
contracts were stated too strongly and both surfaced as
`PANIC: ipclock not held`, on the first boot after the change, rather
than as a race found later.

## Recursion

The buckets are recursive: owner plus depth, per bucket.

The original reason was the `__gc` re-entry above, and stopping the
collector retired it: nothing arbitrary re-enters any more. What is
left is nesting this kernel writes itself, which is auditable rather
than open-ended -- `msg_dispose` takes the wide lock from inside
`alt_take_at`, which already holds it, and `port_unref` reaches
itself through `port_flush` and `release_inflight`.

Whether that is enough to make the buckets non-recursive has not been
tried. `port_unref`'s self-recursion is real and would need answering
first.

The pitfall, because it passes the whole test suite: a bucket whose
owner is set but whose leave is missed is never released, and every
later acquire on that cpu takes the depth fast path and succeeds. The
kernel then runs unlocked and green. What catches it is the assertion
in `kernel_run` that no bucket is held across a lap -- trust that, not
the tests.

## What is not locked

- **A proc's right table.** Read and written only while that proc runs,
  and a proc runs on one cpu at a time. `right_get` and `right_new`
  take nothing. This is what lets a syscall pick its bucket from the
  right it looked up.
- **A proc's Lua heap.** One per proc at `NCPU > 1`, for the same
  reason.
- **A detached message.** Off the queue, before disposal, it belongs to
  one cpu.

## Measuring

`sys.stats().lock` reports `locks`, `contended`, `spin` for both, and
`held` for ipc. The ipc figures are the eight buckets summed.

Contention rate alone is misleading -- the wide form takes eight, so
the denominator moves with the design. `spin` in cycles and wall clock
are what compare across arrangements.

`test/boot/microvm_pairs.lua` is the judge: independent proc pairs over
ports no other pair touches, so the only thing they share is the lock.
`microvm_spin` is its control -- procs that share nothing at all.
