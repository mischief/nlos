# Scheduling

Two schedulers, stacked, sharing one preemption mechanism. The rules
that follow are the ones the code cannot state locally, because they
are properties of how the two levels meet.

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
share of the machine's throughput:

| spinner runs as | share |
| --- | --- |
| a proc's main coroutine | 0.52x — fair |
| a thread, with the forced trip | 0.51x |
| a thread, without it | 0.02x |
| a coroutine two schedulers down | 0.49x |

### Deeper nesting

Arming `p->co` only helps if control returns to `p->co`. A thread that
runs a scheduler of its own — resuming a coroutine in a loop — never
returns, so that trip never fires. The kernel detects this: if the hook
fires in a nested state while `p->co` is *already* armed, the trip
demonstrably did not land, so it arms **every** coroutine of the proc
instead, and the yield then walks out one instruction per level. Depth
one never escalates, so the common case pays nothing.

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

## Where a preempted proc resumes

Into `thread.run`, never into the interrupted coroutine.

The yield happens in `p->co` inside `thread.run`'s loop, so when the
kernel resumes the proc, the scheduler is what continues, and it picks
what runs next by its own policy. Resuming straight back into the
interrupted thread would let one thread hold the cpu across proc
slices, with `thread.run` never getting a say.

## How a message reaches a parked thread

Three paths, in order of preference:

1. **The run queue is empty and every waiter is a plain `recv`.**
   `sys.altrecv` takes a message from whichever port has one and
   `thread.run` hands it straight to the waiter. No wake, no scan.
2. **The run queue is empty and some waiter is not a plain recv.**
   `sys.altblock` blocks and returns a hint naming the port that has
   something; `readyon` wakes only the threads parked on it.
   `readyall` — wake everyone and let each look — is the last resort
   for a wake no port of ours accounts for.
3. **The run queue is not empty.** No wake can arrive: `port_push`
   wakes whoever is *parked on the port*, and a running proc is not
   parked. So `thread.run` asks, every round, with `sys.anyready` — a
   bounded scan of the proc's own rights, no port set to build — and
   pays for the `altpoll` sweep only when the answer is yes.

Without (3), one thread that never parks starves every thread that
does, because (1) and (2) run only when the run queue drains.

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
