# Debugging a running machine

What you can ask a proc, living or dead, and which question each tool
actually answers. The scheduler rules these sit on top of are
`docs/scheduling.md`.

## The three questions

| question | tool |
| --- | --- |
| what is on the machine, and what is it doing | `ps`, `sys.wchan` |
| where is this proc now | `stack pid`, `/proc/n/stack` |
| how did it get there | `trace pid`, `/proc/n/trace` |

Three more arrived with the profiling work — what it costs, which proc
owns the time, and how often it calls into the kernel. They are at the
end, under "Which tool answers which question", together with the order
to reach for them in.

A stack shows the calls that are still *open*. After a fault that is
the shape of the failure rather than the route to it: the call that
returned just before everything went wrong is precisely the one it
cannot show. Tail calls make this concrete — a recursion through
`outer -> inner` reports `dier:8: in function <dier:7> | (...tail
calls...) | dier:11: in main chunk`, with every iteration collapsed
into one marker. The trace has them all.

## Reading another proc

`sys.stack(pid)` returns one entry per **coroutine**, not a flat frame
list. A proc built on `lib/thread` keeps its threads inside its own
state, so reporting only the main one shows the scheduler parked in
`altblock` whether the proc is idle or wedged.

It is safe on anything, including a proc that is running right now,
because the kernel **holds the target still** before reading it. That
used to be free: with one cpu every proc but the caller was suspended
between resumes, so there was no moment at which a stack was
half-built. With more than one, the target can be executing while the
reader walks its frames, and it has to be stopped.

Stopping it rather than refusing is the point. A spinning proc is
running by definition, and it is the one worth sampling — "where is it
stuck" is the question — so declining to read a running proc would
decline exactly the interesting case.

The mechanism is `kproc.frozen` (see `proc_freeze` in `src/kernel.c`):
the target is marked unresumable first, and only then waited for. In
that order there is no window where it gets dispatched again between
the wait and the read. The wait ends even for a proc that never yields,
because the preempt hook cuts one every quantum; and it yields rather
than spins, which is what stops two readers from deadlocking on each
other.

The same holds for anything else that reads or changes another proc:
`sys.trace` walks a ring the target writes on every line, and
`sys.set_trace` frees that ring under a live writer. `proc_hold` is the
shared shape, and the comment above it is the recipe for the next one.

`src/debug.c` keeps three rules that make it introspection rather than
participation, and they are why this works on procs that are nearly
dead:

1. It never runs target code — `lua_next`/`lua_rawget`/`lua_rawgeti`
   only, and `lua_getinfo` with `"Sln"`, which pushes nothing.
   `__index` and `__tostring` are never fired.
2. It never allocates in the target. The visited set is a C array in
   the caller's frame, because a table would be charged to the target's
   `mem_limit` — debugging a proc near its cap could push it over.
3. It leaves the stack as found.

Locals are values rather than structure and are deliberately absent;
when they land they want a capability, unlike this.

## Broke: a proc that died is kept

A proc that dies of an error enters `BROKE` instead of being freed. A
coroutine that errors out of `lua_resume` does not unwind, so at the
moment of death every frame is still standing — `sys.stack` on a corpse
is the same read as on a live proc, because a corpse is a proc
suspended forever.

What a corpse still is:

- listed by `sys.procs`, so it can be found, and `sys.wchan` says
  `broke`
- counted in `sys.stats().broke`, never in `.procs` — corpses hold no
  rights and will never run, and counting them as live would make
  every crash read as a leak
- holding no rights: the run queue, rights and monitors are all
  released at the moment of death, so a broke fileserver fails its
  clients rather than wedging them
- not monitorable — its exit notification has already gone out, so
  `sys.monitor` on a corpse answers `noproc` at once

`MAXBROKE` (2) corpses are kept; breaking past that reaps the oldest,
so this is a cache of recent deaths rather than a graveyard.
`sys.reap(pid)` releases one by hand. Reaping is ambient for the same
reason reading is: what it destroys is already dead, and the cap was
going to discard it anyway.

An out-of-memory death is the case worth knowing about. `kernel_run`
skips `luaL_traceback` on `LUA_ERRMEM` because building the string
would allocate in a proc that has just run out, so that death has never
had a traceback at all — but the corpse is readable, precisely because
of rule 2 above.

A monitor is told: the exit notification carries `broke=true` while the
corpse is still held, so a watcher can `sys.stack` the pid it was just
told about and `sys.reap` it when done. That is the whole
core-pattern-handler mechanism — one flag on a message that was already
being sent.

### What Broke does not catch

`lib/thread`'s scheduler resumes each thread under `coroutine.resume`
and, on failure, prints `thread error:` and drops it
(`lib/thread.lua:371`). A fault inside a thread therefore never reaches
`lua_resume` and never breaks the proc. What breaks is what kills the
proc: a fault in its main coroutine, the deadlock error out of
`thread.run`, or running out of memory.

## Tracing: the last lines a proc ran

`sys.set_trace(pid, entries)` arms a ring; `sys.trace(pid)` reads it,
oldest first, as `{source=, line=, thread=, cpu=, wall=}`. `entries` of
0 frees it. The ring is freed with the proc's state, not at its death,
so a corpse answers "how did it get here" for as long as it answers
"where".

Arming costs the target about **4.7x** (measured: a tight arithmetic
loop, 3ms untraced against 14ms traced). A line hook fires per line
where the preemption hook fires every `REDUCTIONS` instructions. An
untraced proc pays nothing at all — `LUA_MASKLINE` is only in the mask
while a ring exists, so the hook is absent rather than idle, and
turning tracing off measures 1.00x again.

The ring is C memory, not the proc's: charging it to `mem_limit` would
mean the act of debugging a proc near its cap could push it over.
Bounds are `TRACEMAX` 4096 entries, `TRACESRC` 32 distinct source
files, `TRACECO` 16 coroutines told apart.

### Two clocks, and why not one

Each entry carries `cpu` and `wall`, both cycles, both deltas from the
entry before it. One `platform_ticks()` yields both: `p->cputime` and
`p->resumed` already exist for the scheduler, so a proc's running
cycles are `cputime` plus however long it has been on the cpu.

- `cpu` is what the line **cost**. Per-proc running cycles are disjoint
  across procs, so these can be summed and compared.
- `wall - cpu` is how long the proc was **not running** after that
  line — the kernel, another proc, or idle.

Neither answers alone. Per-proc cycles are blind to everything outside
the proc, which is where dispatch, port push and pop and message
serialisation live. Wall sees all of it, and for a voluntary yield
attributes it well — the time lands on the line that called `sys.send`
— but the preempt hook fires anywhere, so an arithmetic line in a loop
absorbs whatever other procs then ran, and two procs' wall timelines
cover the same interval and cannot be added.

**The delta belongs to the line that ran, not the one about to.** A
line hook fires before its line, so the interval between two hooks is
the earlier line's cost. Recording it against the arriving entry shifts
the whole profile by one, which blamed `snd_una = seg.ack` for 7.5% of
the tcp task when the cost was the string reslice above it. The newest
entry therefore reads zero: nothing has happened after it yet.

A `<scheduled>` entry, source `<scheduled>` and line 0, is recorded at
every resume. Without it a context switch is an enormous `wall` on
whichever line ran last and the reader has to guess whether that line
was slow or the proc was simply away.

### Arming in time

A trace has to exist before the death it is meant to explain. Spawning
a proc and then arming it is a race the proc usually wins, and arming a
corpse is refused rather than quietly producing an empty ring. For
anything short-lived, arm it at spawn:

    sys.spawn(src, { name = "dier", trace = 64 })

### Sizing the ring

Budget by wakeups, not by lines of your own code. A `lib/thread` proc
spends most of its instructions in the scheduler — serving one file
read costs `esp` about 860 lines, of which ~700 are `lib/thread.lua`.
A ring of 40 holds one trip through `gatherports` and nothing else. If
you want to see the work, size for roughly 50 lines per wakeup plus
whatever the handler itself runs.

That ratio is not noise to be filtered out; it is what the proc is
really doing, and reading it is how the wakeup path in
`docs/scheduling.md` got fixed.

## Profiling: `sys.tracehist`

`sys.tracehist(pid)` aggregates the ring by source and line, sorted by
`cpu` — rows of `{source=, line=, count=, cpu=, wall=}`, plus
`dropped`. It is the same aggregation everyone was writing in Lua, and
the first time anyone wrote it, it found a task closing and recreating
a kernel timer on every message.

Keyed on source and line, **not** on thread. What a line costs is a
property of the line; which coroutine ran it is a different question,
and the raw ring still answers that.

Computed in C for the reason `src/debug.c` allocates nothing in its
target: handing a 4096-entry table to the reader charges its
`mem_limit` for the act of reading. The scratch table is sized to the
ring and allocated per call, so profiling costs nothing when nobody is
profiling — and it is exact. A fixed table cannot be: aggregation meets
keys in the order they occur, so one that fills stops admitting new
ones, and the rows it then fails to report are not the cold ones but
whichever appeared late. `dropped` is nonzero only if that allocation
failed.

### Count or cost, and which question you are asking

The histogram sorts by cost. Reading it by `count` instead answers the
older question — what runs, and how often — and the two disagree, which
is the point of having both.

From one tcp task, one transfer:

    10.6%  lib/thread.lua:683   48 hits  the scheduler's tryrecv
     7.5%  lib/tcb.lua:1117      7 hits  sndq = sndq:sub(bytes + 1)
     3.1%  lib/tcp4.lua:103     88 hits  tcp4.lt
     2.6%  lib/tcb.lua:576       2 hits  table.concat(self.rcvq)

`tcp4.lt` tops the count and is cheap. The two string operations are
nine executions between them and a tenth of the task, and neither
appears anywhere near the top by count. A count profile finds
repetition nobody intended; only the clock finds a line that is
expensive on its own.

It also has a limit worth stating: a syscall is not a Lua line. The
timer churn above was found because the histogram pointed at the scan
around it and a person then read the code. Nothing in the ring showed
`sys.close` at all.

## Counting: `sys.syscalls`

`sys.syscalls(pid)` returns `name -> count` for the `los.sys` calls a
proc has made, and only the ones it has made, so a zero is an absence
rather than a row of noise. Always on: 38 counters is 152 bytes beside a
whole `lua_State`, and `procv` holds pointers, so it costs per live proc
rather than per `MAXPROCS`.

It exists because **a syscall is not a Lua line.** `sys.tracehist` found
a task rebuilding a kernel timer on every message only as "the scan
around it" — nothing in the ring showed `sys.close` at all, and finding
it meant reading the code from a hint. A count says `timer: 2 per
message` outright.

Counted by a wrapper installed at registration rather than by an
increment inside each call, so a syscall added to `kapi` later is
counted without anyone remembering to. `kapi`'s array order is the
index and `kapi[i].name` gives the name back, so there is nothing to
keep in sync.

Counts and not cycles, deliberately. Two TSC reads per syscall is real
overhead on the cheapest ones, and the line profile already prices the
line a syscall sits on. What it cannot say is how many calls that line
made and which — which is all this adds.

Read it as a rate against whatever the proc is doing, not as a total.
From the tcp task, per data segment:

    tryrecv     6.36    the scheduler's port scan in alt
    uptime_ms   2.79    one per pass of the message loop
    send        2.67    the segment and its acknowledgment
    close       0.52    reply rights
    timer       0.03    was 2 per message before it was fixed

## Which tool answers which question

| question | tool |
| --- | --- |
| what is on the machine | `ps`, `sys.wchan` |
| where is this proc now | `stack pid` |
| how did it get there | `trace pid` |
| what does it run, and how often | `tracehist pid`, read by `count` |
| what does it *cost* | `tracehist pid`, read by `cpu` |
| where does it block | `tracehist pid`, `wall` minus `cpu` |
| which proc owns the time | `sys.pidstat(pid).cputime`, differenced |
| how much is the kernel's | wall clock minus the sum of those |
| how often does it call in | `sys.syscalls(pid)` |

The last three are the ones that are easy to reach for in the wrong
order. Narrow to a proc with `cputime` first — it is exact, costs
nothing, and it is the only one that can see the kernel's own share,
since a line hook fires only inside Lua. Then profile inside whichever
proc dominates.

## Where to find it

From the lua repl (`init.lua` wires these as globals):

    ps                  the process table, printed live
    stats               ports, heap, lua memory, corpses
    stack(pid)          every coroutine of that proc
    trace(pid)          its ring, runs of one line collapsed
    tracehist(pid)      the same ring by cost, hottest line first

Arming stays an explicit `sys.set_trace` rather than another magic
word, because unlike the others it has an effect on the target.

From `dos`:

    stack pid
    trace pid           dump the ring
    trace -n 64 pid     arm one, then read it back later

Through the filesystem, which is the point of `lib/procfs.lua` — a
debugger stops being a program and becomes `cat`:

    /proc/n/status      name, pid, wchan, weight, pri, cpu
    /proc/n/stack       the cross-proc traceback
    /proc/n/trace       the ring, or "(not traced)"
    /proc/n/mem         used, peak, limit
    /proc/self/...      resolved by whoever is reading

`/proc` is read-only, deliberately: everything it reports is structure,
which is why it needs no capability. It reports a trace but will not
arm one, because arming is an effect on another proc rather than a
report about it.
