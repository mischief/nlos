# Scheduling

Two schedulers, stacked, sharing one preemption mechanism. The rules
that follow are the ones the code cannot state locally, because they
are properties of how the two levels meet.

The short version: the kernel preempts **procs**, so no proc can hold
the machine. `thread.run` does not preempt **threads** — a thread runs
until it parks, yields or exits, which is plan 9 libthread's contract.
The hook cuts threads anyway, because that is the only way the proc can
be descheduled, but nothing observes it: every level resumes what it
interrupted, at the instruction it interrupted.

## The hierarchy

    kernel_run (src/kernel.c)          picks a proc, resumes p->co
      └─ thread.run (lib/thread.lua)   picks a thread, resumes it
           └─ a thread

The kernel owns procs; `thread.run` owns threads. Neither knows how the
other decides. A proc that never calls `require("los.thread")` has no
second level at all — its chunk runs directly in `p->co`.

`p->L` is the proc's `lua_State`; `p->co` is a thread of it, created in
`proc_new`, and is what the kernel resumes. Every other coroutine of
the proc is created by Lua.

## The quantum

A slice is `QUANTUM_MS` (2ms) of wall clock, not a count of
instructions: how much work N instructions buy depends entirely on
which instructions they are. The count hook is only the sampling rate —
`preempt_hook` fires every `REDUCTIONS` (25000) VM instructions, checks
`platform_ticks() - p->resumed` against the quantum, and returns
without yielding if the slice is not spent.

`lua_newthread` copies hook, mask and count into every coroutine at
creation (`lua/lstate.c`) and never revisits them. Two consequences,
and both matter:

- A coroutine is born already preempted, so `coroutine.create` is not a
  way out of the instruction budget. `debug.sethook` is stripped from
  non-boot procs (`kernel_strip_debug`) because it *would* be one.
- A mask set on one coroutine reaches no other. Anything that changes
  hook state for a proc — tracing, the forced trip below — has to reach
  every coroutine, not just `p->co`.

Every `lua_sethook` in the kernel takes its mask from `proc_hookmask`
and its count from `p->reductions`, so `LUA_MASKCOUNT` cannot be
dropped by accident.

## Where a yield lands

`lua_yield` unwinds to the resumer of the state it is called on. This
is the rule the whole design turns on.

- Hook fires in `p->co`: the resumer is the kernel's `lua_resume`, so
  the proc is descheduled. This is the case the hook was written for.
- Hook fires in a thread: the resumer is `thread.run`, one level below
  the kernel. The thread is suspended, `thread.run` gets control back,
  and **the proc keeps the cpu**. The quantum decides nothing.

Lua has no yield-across-levels, so the kernel forces the trip: when the
hook fires in a state other than `p->co` with the quantum spent, it
arms `p->co` to fire on its very next instruction. The thread yields to
`thread.run`, `thread.run` executes one instruction, and the hook fires
again where a yield does reach the kernel.

The cost of getting this wrong is not subtle. A competing spinner's
share of the machine's throughput — this is fairness between **procs**,
which is the only fairness promised; threads inside one proc share by
yielding to each other and not otherwise:

| spinner runs as | share |
| --- | --- |
| a proc's main coroutine | 0.52x — fair |
| a thread, with the forced trip | 0.51x |
| a thread, without it | 0.02x |
| a coroutine two schedulers down | 0.49x |

### A park is not a preemption

Everything above is about the **hook**, and the walk-out makes it reach
any depth. A **park** gets no such help, and the difference is the one
that bites.

`sys.block`, `sys.call`, `sys.altblock`, `sys.altrecv` and
`sys.sendblock` all end in `lua_yield`, and they mark the proc `BLOCKED`
and take it off the run queue *before* yielding. The kernel cannot arm
its way out of this the way it does for the hook: a park has already
changed the proc's state, so if the yield lands short of `kernel_run` —
in `thread.run`, or in some library's `coroutine.resume` — the proc is
recorded as parked while it carries on executing. Nothing errors. What
shows up is a stall somewhere else entirely, in whatever waits for the
message that was never going to come.

So the five refuse it outright: **illegal parking**, raised at the call
site, from a state that is not `p->co`. The check sits before any state
change, so a call that finds its message already waiting is still
answered from any depth, and a raise never leaves a waiter registered
behind it.

`test_ipc` used to pin the opposite -- it tolerated the first such block
and refused the second, "where the mistake is". The first is earlier
still, and the second was only reachable because the first left the proc
in the split state.

Correct code never meets this. A thread parks by yielding to
`thread.run`, which does the real block from the top: that is what
`thread.park`'s `inthread()` branch is for, and `thread.recv`,
`thread.await` and `thread.parksend` all go through it. The rule bites
library code that owns a coroutine and calls back into user code -- a
sans-io protocol driver, say, whose reader parks. The fix there is the
one `lib/zmodem.lua` uses: hand the request *out* of the coroutine and
let whoever is driving do the blocking, which is the same shape as
`thread.run` doing it for a thread.

### Deeper nesting

Arming `p->co` only helps if control returns to `p->co`. A thread that
runs a scheduler of its own — resuming a coroutine in a loop — never
returns, so that trip never fires. The kernel detects this: if the hook
fires in a nested state while `p->co` is *already* armed, the trip
demonstrably did not land, so it arms **every** coroutine of the proc
instead, and the yield then walks out one instruction per level. Depth
one never escalates, so the common case pays nothing.

This is what makes the containment real, and it is why nested
coroutines are still preempted rather than exempted: without it, four
lines — `coroutine.create` and a `resume` loop — hold the machine for
as long as the proc likes. `test_nesting.lua` spawns a separate proc
that does exactly that and measures what everyone else still gets.
What the walk-out costs a *correct* coroutine is handled above.

That needs an exact list of a proc's coroutines. `src/debug.c`'s
reachability walk will not do: it misses any coroutine held only from a
C closure's upvalue or a live local, and it allocates, which is not
allowed on a path that runs inside the hook and may run while the proc
is at its memory limit. `src/coreg.h` keeps the list instead, linked
through each state's extra space and maintained by lua's
`luai_userstatethread` / `luai_userstatefree` hooks, so every
`lua_State` is on it from creation to free — including ones created
from C. It is injected through `LUA_USER_H`, which is what that hook
exists for and what lua's own `ltests.h` uses; `lua/` is a submodule of
upstream and is not patched.

The links live there rather than in a table in the proc's registry for
two reasons: nothing on this path allocates, and a registry table is
reachable through `debug.getregistry`, which non-boot procs keep — so a
proc could clear the mechanism meant to contain it.

## What it takes to lose the cpu

A thread is switched away from where it chose to be and nowhere else:
parking on a channel or port, calling `thread.yield`, or returning.
That is plan 9 libthread's contract. Nothing preempts a thread against
its siblings, and the locks libthread has are for state shared between
procs and across yields — not against being cut mid-update.

The count hook still cuts a thread wherever it likes, because that is
the only way control reaches `p->co` and so the only way the *proc* can
be descheduled. What `thread.run` does afterwards is resume the same
thread, at the same instruction. The proc still yields to the kernel on
its quantum; only the thread underneath carries on.

The two yields arrive at `thread.run` looking identical — a suspended
coroutine that is not parked — so they are told apart by what they
carry. The hook's `lua_yield` passes no values; `thread.yield` passes a
private sentinel. A bare `coroutine.yield()` from a thread therefore
reads as a hook cut and hands the cpu straight back, which is a spin
rather than a yield: use `thread.yield`.

The cost is the usual one. A thread that neither parks nor yields keeps
the proc until it exits. That is a bug in the thread rather than
something the scheduler defends against — and defending against it is
what once made every multi-step update in `lib/thread.lua` a critical
section, along with the fid and tag allocators in `lib/p9fs.lua` and
`lib/srv.lua`. Those are plain read-modify-writes again.

`test_preempt.lua` pins what is still promised; `test_torture.lua`
measures the rest by cutting a thread between every pair of
instructions and checking that nothing observes it.

## Generators, and yields nobody asked for

`lua_yield` unwinds to the resumer of the state it fired in. For a
thread that is `thread.run`, which knows what the yield meant. For an
ordinary coroutine it is whoever called `resume` — and `for v in
seq(n)` reads a yield of no values as the generator being finished, so
the loop ends early and the caller gets short data with no error.

It was a function of work done per item, which is a quantum showing
through. Items delivered out of ten: ten at trivial work, three at
10000, none at 200000, none at all inside a thread.

Not preempting nested coroutines would fix it and is wrong — the
walk-out below is the only thing between a proc and the whole machine.
A watchdog instead is worse: its timeout is how long one buggy proc
freezes everything, and `MAXPROCS` is 4096.

So `coroutine.wrap` resumes again rather than believing the yield
(`kernel_cowrap`). Being stopped does not disturb a coroutine, so
carrying on lands at the instruction it was stopped at. It yields
*itself* first, so the level above still gets to deschedule the proc —
which works only because every level now resumes in place.

`coroutine.resume` is left raw on purpose. It is what a scheduler uses,
and a scheduler has to see the preemption: `resume_one` in
`lib/thread.lua` is exactly this.

## How a message reaches a parked thread

Three paths, in order of preference:

1. **The run queue is empty and every waiter is a plain `recv`.**
   `sys.altrecv` takes a message from whichever port has one and
   `thread.run` hands it straight to the waiter. No wake, no scan.
2. **The run queue is empty and some waiter is not a plain recv.**
   `sys.altblock` blocks and returns a hint naming the port that has
   something; `readyon` wakes only the threads parked on it. A thread
   waiting for room is one of these -- see "How a thread waits for
   room" -- since it must not be handed a message it has nowhere to
   put.
   `readyall` — wake everyone and let each look — is the last resort
   for a wake no port of ours accounts for.
3. **Something is still runnable** — the run queue is not empty, or a
   thread is about to be resumed in place. No wake can arrive:
   `port_push` wakes whoever is *parked on the port*, and a running
   proc is not parked. So `thread.run` asks, every round, with
   `sys.anyready` — a bounded scan of the proc's own rights, no port
   set to build — and pays for the `altpoll` sweep only when the answer
   is yes.

Without (3), one thread that is merely slow between parks starves every
thread that is waiting, because (1) and (2) run only when nothing is
runnable. Staging a wakeup switches nobody, so this costs a busy thread
nothing but keeps its siblings' messages moving.

## How a thread waits for room

The section above is the receive side. A thread that wants to **send**
on a full port has the same problem and, for a while, a worse answer:
`parksend` called `sys.sendblock` directly, on the grounds that the
scheduler's park reasons were receive-shaped -- `thread.run` hands a
port set to `sys.altblock`, and "wait for room" is not a port set. What
actually happened was neither parking the thread nor parking the proc:
the yield reached `thread.run`, which reads a coroutine with no park
sentinel as a hook cut and resumes it, so the send never waited at all.

The kernel had always been able to say it. `wait_add(p, port, send)`
takes the flag, `wake_senders` and `wake_receivers` walk the same list
and skip what is not theirs, and `sys.sendblock` has always passed 1.
Only `api_altblock` hardcoded 0.

So `sys.altblock(set, sends)` takes a second, parallel table: where
`sends[i]` is a size, entry `i` waits for room for that many bytes
instead of for a message, and is ready when `qbytes + need <= MAXQUEUE`
(or when the port is dead, since then the send itself should report it).
A parallel table rather than a boxed entry per case, because the
all-receive park is nearly every park and should allocate nothing.

`parksend` therefore registers a park record like `parkon` does, marks
itself `nonrecv` -- it must not be handed a message it has nowhere to
put -- and yields. `readyon` needs no change: a send wait carries
`r.port` like any other, so the ready-port hint finds it.

One park now covers both directions, which retires the asymmetry the old
`parksend` documented: a thread waiting for room no longer stalls its
siblings.

Neither reference system could lend us this. plan9front's libthread
blocks a thread on a channel with `_threadrendezvous`, which is
user-level and woken by the peer thread, and refuses to make a blocking
*syscall* from a thread at all -- `ioproc.c` spawns a proc whose whole
job is to sit in one, and `ioread`/`iowrite` talk to it over channels.
Go hands the P to another M in `entersyscall`. Both keep the scheduler
off the blocking path by finding another context to block in; we have a
third option, because our ports can already say which way a waiter is
waiting.

## Hangups

A hangup is the one wake a ready-port hint can never name: the thread
that has to notice its peer is gone is precisely the one with nothing
queued. `wakehungup` asks `sys.hungup` of the ports in `altset`, which
is exactly the ports some thread of this proc is parked on, so a hangup
anywhere else is not this proc's to notice.

It runs on **every** wake, not only when the wake came back
empty-handed: a hangup and a message can arrive in the same wake —
unmounting sends a clunk and then drops the right — and taking the
message consumes the wake that would otherwise have reported the
hangup.

`sys.hangups()` still exists but `lib/thread.lua` does not use it. It
counts every port on the machine losing a reference, so it moves
constantly on any system where anything else is doing request/reply
(measured: one file read moves it by 8) and cannot answer a question
about one proc.

## What preemption still cannot do

The hook fires between VM instructions, so it cannot interrupt a single
long C call: `string.rep("x", 1e8)` holds the machine for as long as it
takes. That needs an interrupt, which means leaving boot services.
