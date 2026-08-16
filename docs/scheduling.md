# Scheduling

Two schedulers, stacked, sharing one preemption mechanism. The rules
that follow are the ones the code cannot state locally, because they
are properties of how the two levels meet.

The short version: the kernel preempts **procs**, so no proc can hold
its cpu. `thread.run` does not preempt **threads** — a thread runs
until it parks, yields or exits, which is plan 9 libthread's contract.
The hook cuts threads anyway, because that is the only way the proc can
be descheduled, but nothing observes it: every level resumes what it
interrupted, at the instruction it interrupted.

## The hierarchy

    kernel_run (src/kernel.c)          picks a proc, resumes p->co
      └─ thread.run (src/thread.c)   picks a thread, resumes it
           └─ a thread

One of these stacks per cpu. On microvm there may be several; every
other platform has one. Nothing below the kernel notices: a proc runs
on one cpu at a time, so a thread's world is unchanged, and the run
queues and the lap are per cpu rather than per machine (`struct cpu`,
`src/cpu.h`, and AGENTS.md's "More than one cpu"). Read "the cpu"
below as this proc's cpu, not the machine's only one.

The kernel owns procs; `thread.run` owns threads. Neither knows how the
other decides. A proc that never calls `require("los.thread")` has no
second level at all — its chunk runs directly in `p->co`.

Not having it is worth about 4KB, measured on esp32 as two parked procs
differing only in the require. So `lib/prog.lua` requires it where it
is used rather than at the top, and takes its one unavoidable receive —
the ABI message — with `sys.alt`, which needs no scheduler. A
program that neither spawns a thread nor blocks on a stream never opens
the module. `sys.alt` is legal there because `M.main` runs at the
top of the proc, which is the one place `nopark` is satisfied by
construction rather than by care.

`p->L` is the proc's `lua_State`; `p->co` is a thread of it, created in
`proc_new`, and is what the kernel resumes. Every other coroutine of
the proc is created by Lua.

A thread ends by returning, or by `thread.exit()` from anywhere inside
it — plan 9's threadexit, and the run loop counts it finished rather
than faulted, so nothing is printed. `thread.run` returns when the last
one goes, which is what ends the proc in the ordinary case.

Ending the **proc** from a thread is `sys.exit`, and the distinction is
not pedantry: raising or exiting unwinds one coroutine, so a thread that
does it leaves its siblings parked on ports nobody will write to and the
run loop turning forever with nothing to run.

## The lap

The kernel dispatches in laps. Each lap runs two phases over the run
queues, then the device pumps, the timers and the firmware tick. Phase
one takes the highest priority first, so an interactive proc answers
before a hog gets another turn. Phase two takes whatever is left,
priority never consulted, including anything woken during phase one.

Phase two is the starvation guarantee, and it is deliberately
independent of the priority function: every proc runnable when the lap
began runs once in it whatever `reprioritize` computes, and one woken
during the lap runs in it or the next. A policy that is buggy, hostile
or merely untuned can cost latency; it cannot wedge the machine. That
matters because policy is the part we expect to get wrong.

"Already had its turn" is membership in `donq` rather than a per-lap
marker, so nothing here is sized against `MAXPROCS` and nothing scans.
The lap ends when `runq` is empty, and whichever cpu empties it swaps
the two. With one queue that is the only workable boundary — a cpu
cannot swap on its own schedule without handing the others procs that
already had a turn. Counting the cpus inside a lap and letting the last
one out swap livelocks instead: cpus finishing early re-enter at once,
so they are never all out together, and every cpu churns empty laps over
a `runq` whose procs all sit in `donq`.

### Why phase two is bounded

The bound is what makes a lap terminate at all. A proc woken mid-lap
joins the current `runq`, so two procs feeding each other hand phase two
a fresh proc every time it takes one. An unbounded drain never reaches
the top of the loop again — where the timers and the device pumps live —
so one busy pair would stop every timer on the machine.

`LAPSPILL` is the floor on that bound, and it is sized to amortize
rather than merely to terminate. Everything between laps costs a fixed
toll: a port write on a virtual machine, several firmware calls on efi.
A bound of "whatever was queued" charges a ping-pong pair the whole toll
on every exchange, which measured several times the cost of the round
trip itself. What it costs in return is the delay a busy pair can impose
on a timer, which is this many round trips — well under one tick.

## The quantum

A slice is `QUANTUM_MS` (2ms) of wall clock, not a count of
instructions: how much work N instructions buy depends entirely on
which instructions they are. The count hook is only the sampling rate —
`preempt_hook` fires every `REDUCTIONS` (25000) VM instructions, checks
`platform_ticks() - p->resumed` against the quantum, and returns
without yielding if the slice is not spent.

A slice costs one lap, so the quantum decides how much of the machine
goes to scheduling rather than to work. A platform whose lap is
expensive overrides it in `param.h`. The bound it must respect is the
timer, not the tick: timers expire once per lap, so a busy proc delays
one by at most a quantum, while an idle machine cannot beat the tick
anyway.

`REDUCTIONS` is measured at boot rather than fixed, because the right
value depends entirely on how fast the machine executes bytecode. A
fixed count is a different fraction of the quantum on every machine, and
on a slow one it can exceed the quantum outright — at which point time
slicing quietly degrades back into instruction slicing. Calibration
targets a fixed fraction of the quantum instead, so the overshoot bound
holds anywhere.

Frequency scaling makes that approximate, deliberately. An invariant
cycle counter is what makes a usable clock, and is exactly why it does
not track how fast instructions retire. The quantum check stays correct
regardless, because both sides of it are in cycle units; only the
sampling granularity drifts, and the overshoot stays bounded by one
period either way.

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

`sys.block`, `sys.call`, `sys.alt` and
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
lines — `coroutine.create` and a `resume` loop — hold their cpu for
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
what once made every multi-step update in `src/thread.c` a critical
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
`src/thread.c` is exactly this.

## How a message reaches a parked thread

Three paths, in order of preference:

1. **The run queue is empty and every waiter is a plain `recv`.**
   `sys.alt` takes a message from whichever port has one and
   `thread.run` hands it straight to the waiter. No wake, no scan.
2. **The run queue is empty and some waiter is not a plain recv.**
   `sys.alt(set, sends, nil, true)` -- `wake`, so it takes nothing --
   blocks and returns a hint naming the port that has something;
   `readyon` wakes only the threads parked on it. A thread waiting for
   room is one of these -- see "How a thread waits for room" -- since
   it must not be handed a message it has nowhere to put. Taking here
   would be worse than useless: one port may be waited on both ways at
   once, and only the thread waiting to receive may have the message.
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
port set to `sys.alt`, and "wait for room" is not a port set. What
actually happened was neither parking the thread nor parking the proc:
the yield reached `thread.run`, which reads a coroutine with no park
sentinel as a hook cut and resumes it, so the send never waited at all.

The kernel had always been able to say it. `wait_add(p, port, send)`
takes the flag, `wake_senders` and `wake_receivers` walk the same list
and skip what is not theirs, and `sys.sendblock` has always passed 1.
Only the scheduler's own park hardcoded 0.

So `sys.alt(set, sends)` takes a second, parallel table: where
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

`sys.hangups()` still exists but `src/thread.c` does not use it. It
counts every port on the machine losing a reference, so it moves
constantly on any system where anything else is doing request/reply
(measured: one file read moves it by 8) and cannot answer a question
about one proc.

## The run queues

One pair for the machine, not one pair per cpu. Any cpu takes the next
runnable proc from the same place, so a proc is never stuck behind a
busy cpu while another idles, and there is no placement decision to make
at spawn. That decision is the one that cannot be made well: it is made
before the proc has done anything, and nothing revisits it. Plan 9's
`runq` is global for the same reason, where OpenBSD uses per-cpu queues
and work stealing.

`p->home` survives as a record of where a proc last ran — affinity as a
report, not a placement. Nothing decides anything from it today. It
answers "which cpu is this on" for the smp tests, and soft affinity, if
it is ever wanted, is a use of exactly this field.

### What the single lock costs

The usual argument for per-cpu queues is keeping cpus off one lock on
the hottest path. That was dismissed while the ipc lock was always held
longer, so this one could not contend first. Splitting the ipc lock into
buckets ended that: at eight cpus, a ping-pong benchmark leaves
`schedlock` heavily contended while the ipc buckets are nearly free. It
is the ceiling now. Below eight cpus it is not — the same test is flat
from one to four — so this is a real problem at one width and not yet at
the others.

What costs is the number of acquisitions, not the work under them.
Timing the critical sections says the lock is held for well under half
the cycles a run takes, while the cpus spin for several times that
between them: a section is a few tens of cycles of work on one cpu and
several times that when eight are passing the line around, and it is
that handoff being paid millions of times. Proportional backoff in the
spin was tried and measured nothing, which is the same finding from the
other side — the waiters are not the problem, the traffic is.

So `dispatch_phase` folds the requeue of the proc just run into the same
acquisition as the take of the next one, and reads its bound there too.
That cut roughly a quarter of the acquisitions and a third of the
spinning, for about a fifth off the wall clock. What is left is around
seven acquisitions per round trip: one per dispatch, one per
`make_ready`, one per `proc_block`, and the lap boundary.

Splitting further has two shapes. Plan 9's is to lock each priority
queue separately rather than the whole set, which does nothing for a
workload whose procs all sit in one bucket — this one. The other is
per-cpu queues, which is what made the ipc side cheap, and which is
exactly what the top of this section gives up on purpose.

## Priorities

`sys.set_priority` writes a clamped weight, and that is the whole of the
policy interface. The dispatch loop reads it every lap, so no lua runs
inside a scheduling decision and a crashing policy proc cannot wedge or
corrupt dispatch — the reason `sched_ext` bounds its programs rather
than letting them be the dispatcher. It is gated on the scheduling
capability, or any child could hand itself the largest weight and starve
every other proc.

Weight 1 is plain round-robin. A higher weight is a proportionally
bigger share, taken as being resumed up to `weight` times per lap
instead of once.

Dynamic priority is inversely proportional to recent cpu use against an
equal share, clamped to the static weight — plan 9's `reprioritize`,
with weight playing `basepri`'s part. A proc using exactly its share
lands at its weight, a hog sinks toward zero, and one that has been
starved clamps to the top. Nobody is demoted by a rule.

It is computed when a proc is made ready rather than at dispatch, so the
dispatcher only reads an integer, and the computation runs once per
wakeup instead of once per ready proc per lap. That depends on the decay
being independent of how often it is sampled.

### The fair-share estimate

`p->cpu` is an exponentially weighted average of the fraction of wall
time a proc spent running, in per-mille, measured from the cycle
counter.

An instruction count was tried and dropped. The hook fires every N
instructions, so counting the fires is an exact reduction count — but
only for procs that reach their period. A proc that yields sooner
registers zero, which is most ipc-bound work, and lua exposes no way to
read the partial countdown. Exact reductions would mean patching the vm,
and vanilla lua stays vanilla. Cycles have no floor, catch time spent in
C too, and are what real schedulers use.

Plan 9 samples "was this proc running at the tick" and decays from
there, which suits a tick-driven kernel. Procs here run for tens of
microseconds at a time, far below the clock, so sampling would read zero
forever. The fraction is computed directly from measured cycles and then
averaged. The decay is lazy: a closed form over the elapsed interval, so
a proc untouched for seconds decays correctly in one call and no
periodic sweep is needed.

Two traps in the arithmetic, both of which read as a large systematic
undercount rather than as a failure:

- The mixing weight is `n/D`, which approximates a true exponential only
  while `n` stays small next to `D`. `SCHED_DECAY_MS` must therefore
  stay well above the lap period. When the estimate was computed on
  demand instead of every lap, `n` could reach a third of the window and
  the linear form ran far off the real figure.
- The fraction is formed straight from cycles. Converting to whole
  milliseconds first truncates, which was harmless when `n` was hundreds
  of milliseconds and is a systematic undercount at lap scale.

The window converges in roughly three times its own length, which suits
procs that live for seconds.

## Idle and accounting

`cpu_self()->current` is who is running now, set around every resume and
cleared after. Plain C with no `lua_State` — the `fopen` reached from
lua's io library — uses it to find out who is asking, and it is the only
way to check a capability from a context where the caller's state is not
available at all.

The idle counter advances whenever the dispatch loop finds every proc
blocked and goes to a real firmware sleep. It separates a genuinely idle
machine, which advances it steadily, from one busy-spinning with some
proc always ready, which never does. That distinction is otherwise
invisible from inside a proc: sampling `wchan` cannot see it, because a
task woken and re-blocked between two samples looks identical to one
that never woke.

Dispatch accounting is plain counters, for answering where a round trip
goes without guessing. Laps per round trip is what showed that a
ping-pong pair never reaches the top of a lap, and therefore that the
serial pump is no bound on how long the uart fifo goes undrained.
Anything needing a timestamp belongs in a temporary probe rather than
there.

`sys.pidstat(pid)` reports `cputime` and `resumes`: the same
milliseconds spread over thousands of resumes is a proc round-tripping
on ipc; over a handful, one doing its work in a block.

## What preemption still cannot do

The hook fires between VM instructions, so it cannot interrupt a single
long C call: `string.rep("x", 1e8)` holds its cpu for as long as it
takes. Interrupting that needs a real timer interrupt, which is a
platform question rather than a scheduler one: efi has none to give,
because the firmware owns interrupt state under TPL. microvm does, and
does not use it for this — the hook is still what cuts a proc there, so
the limit is the same on both. What differs is that on microvm the
other cpus keep running.
