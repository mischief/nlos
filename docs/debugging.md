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

`los.thread`'s scheduler resumes each thread under `lua_resume` and, on
failure, prints `thread error:` and drops it (`resume_one` in
`src/thread.c`). A fault inside a thread therefore never reaches
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
Bounds are `TRACEMAX` 16384 entries, `TRACESRC` 32 distinct source
files, `TRACECO` 16 coroutines told apart. Ask for the size you need
and check what you got: a ring smaller than the operation wraps, and
the histogram then describes its tail while reading as though it
covered all of it.

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

Budget by wakeups. The scheduler is C and runs no lua lines, so the
ring holds only the handler's own work — roughly 50 lines per wakeup
for a file server, and nothing between them.

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

## Stopping: `los.dbg`

Tracing and stacks answer where a proc is and how it got there. The
debugger answers a third question — *stop here and show me this value*
— and it cannot live inside the proc it debugs: `kernel_strip_debug`
takes `debug.sethook` away from every non-boot proc, and
`kernel_confine_load` forces text-only chunks. So it is kernel-side C
plus a client proc, and cross-VM by construction: client, kernel,
target.

`los.dbg` is a module of its own rather than more `kapi[]` entries, so
its calls are not counted by `sys.syscalls`.

### Authority

Two rights, either sufficient, on every call that acts on a proc or
reports its data:

- a right to the target's self port — what `sys.spawn` returned to its
  parent. The same right `sys.kill` and `sys.set_trace` take.
- a right to `dbgport`, a kernel-held capability minted beside
  `clockport` and granted to proc 0 as `dbg`. It authorizes debugging
  **anything**, which is what makes a boot service reachable: nothing
  holds a right to init's children but init. `init.lua` hands it to the
  serial console and to `dos`, and nowhere else.

Reads that report only structure — `status`, `coros`, `frames`,
`breaks` — stay ambient, the line `sys.stack` already draws. Locals and
values are the target's *data* and are on the acting side of it.

### What the dbg right is worth, and what contains it

It is the most powerful object on the machine: total read and control
of any proc — stop, step, breakpoints, locals, upvalues, values. So its
containment is the whole of its security, and there is not much of it:

- **It can be re-sent.** Rights are copied, not moved, so any holder can
  hand a copy to anyone. Nothing in the kernel tracks where it went.
- **It cannot be revoked.** A right ends when its holder closes it or
  dies; there is no call that reaches into another proc and takes one
  away. Granting it is therefore permanent for the life of the holder.
- **It is granted in exactly two places**, both in `init.lua`: the
  serial console's repl worker, and `dos` when the repl starts it. A
  public session — sshd, webterm — is given none, the same rule
  `power` follows.

The one containment that is structural: **`dbg run PROG` needs no
capability at all**, because spawning the target *is* the right to it.
A tool that debugs what it launches never has to be given this.

Being reachable from a confined proc is deliberate — the repl worker is
`PRIV_NONE` — and it is why `push_desc` reports light userdata without
an address. A `los.sys` closure holds the kernel's own `lua_CFunction`
in its first upvalue, and reading another proc's upvalues reaches those
closures; `dbd1474` closed that leak from the inside, and the debugger
must not reopen it from the outside. `test/boot/test_dbghole.lua` walks
a proc parked inside a syscall and asserts the pointer does not come
back.

### How a proc stops, and stays stopped

The preemption walk-out is the whole mechanism; the debugger adds no
second one.

A line hook fires in some state `L`, possibly nested inside a
`lib/thread` scheduler. `dbg_line` matches a breakpoint and does what
preemption does: arm `p->co` at a count of one, mark `kextra.preempted`,
yield. **`L` is now suspended exactly at the breakpoint line with every
frame standing** — nothing unwound, which is the same property that
makes a `BROKE` corpse readable. The yield reaches `L`'s resumer, and
both resumers defer their re-resume behind a yield to the kernel:
`resume_one` stashes the thread in `s->inplace`, `kernel_cowrap_resume`
yields outward. So if the kernel never resumes `p->co`, no instruction
of the target runs.

The stop is therefore **two-phase**, and the commit point is the kernel
boundary rather than the hook:

- in the hook: record where, set `pending`, walk out. Advisory.
- in `run_proc`, after `lua_resume` returns `LUA_YIELD`: observe
  `pending`, set `STOPPED`. Placed before the existing `status != READY`
  test, so the proc leaves the queue by the rule everything else uses.

Phase one can be swallowed — `kernel_cowrap_resume` re-resumes a cut
coroutine without reaching the kernel when the frame below is not
yieldable, and `p->torture` skips the walk-out entirely. `pending`
survives, so the bound is honest and worth knowing: **a breakpoint hit
under a non-yieldable frame stops at the first yieldable point after
it, not at the line.** A tortured proc cannot be attached to at all;
the two do not compose.

### `STOPPED`, not `frozen`

`frozen` is the short mutual exclusion a cross-proc syscall holds.
`STOPPED` is a long-lived parked state. Both exist and they are
orthogonal, because `frozen` cannot do this job:

- it keeps the proc on a queue, so `dispatch_phase` would shuffle a
  proc stopped at a breakpoint between `runq` and `donq` every lap of
  every cpu, spending the lap budget `expire_timers` and `pump_eth`
  depend on.
- it is a count, so a concurrent `sys.stack` reader's thaw could not be
  told from a debugger's stop.
- `push_wchan` switches on `status`, so a stopped proc would read
  `ready` in `ps` — the one tool someone debugging is looking at.

A proc stopped while **blocked** runs no hook at all. Its request is
left for `make_ready`, which diverts the wake: it wakes *into* the stop
rather than into execution. Nothing is lost — the wakers skip a
non-`BLOCKED` proc before `make_ready` is ever reached, so the waiter
stays linked and the message stays queued, and continuing resumes the
block continuation, which re-polls.

### Locking

Every entry point uses `proc_hold`, the shape `sys.stack` established.
That is not bookkeeping: it guarantees no cpu is inside `lua_resume` of
the target, which is what makes `lua_sethook` on its coroutines legal
at all, and it is the lock for `struct kdbg`. Arming a state another
cpu is executing is a data race.

Three fields escape it and all are atomic, following `kproc.woken`:

| field | written by | read by |
| --- | --- | --- |
| `pending` | the target's own hook | `dbg_commit`, on its cpu |
| `stopreq` | the debugger | the target's hook |
| `notify` | whoever commits a stop | `dbg_sweep` |

`notify` exists because of `docs/locking.md`: sending a message needs
the wide ipc lock, a stop is committed while holding `schedlock` or a
bucket, and a narrow region may never widen. So no notice goes out
where a stop is decided. `dbg_sweep` sends them all, once per lap,
holding nothing.

The same rule shapes the orphan case. A debugger that dies leaves a
target that cannot notice — it holds no right to its debugger and, if
stopped, is not running. `dbg_sweep` marks it and wakes it; `dbg_settle`
tears the state down at the top of `run_proc`, the one place a cpu
provably owns the proc. Freeing it from the sweep would race a target
running on another cpu.

Two rules follow from that table, and both were bugs first:

- **`dbg_free` runs entirely inside the wide lock.** `dbg_sweep` reads
  `p->dbg` there, so clearing and freeing it anywhere else is a
  use-after-free on whichever cpu is walking the proc table.
- **`dbg_mark_orphan` tests and sets the status under one `schedlock`
  hold, and asks again on every sweep.** A proc that commits a stop
  between the test and the set would otherwise be marked detached and
  never woken — the exact stranding the orphan path exists to prevent.

`test/boot/microvm_dbg.lua` is the judge: a spinner on one cpu, stopped
and continued a few hundred times from another, then two hundred
attach/detach cycles against it while it runs. It runs at `-smp 2` and
`-smp 4`.

### Reading values

`sys.stack` reports structure and never touches a value. Reading values
adds two hazards to `src/debug.c`'s three rules, and both are in
`push_desc` and `hop`:

- `lua_getlocal` and `lua_getupvalue` **push** onto the target, where
  `lua_getinfo("Sln")` does not. So rule 3 stops being free: the top is
  recorded outside the `pcall` and restored on every path, error
  included, because building the result allocates in the *caller* and
  the caller has a memory limit.
- `lua_pushstring` on the target would break rule 2. Looking a string
  key up the obvious way — push the key, `lua_rawget` — interns that
  string in the target's heap and charges its `mem_limit`, so *reading*
  a proc could push it over its cap. String keys are found by scanning
  with `lua_next` and comparing bytes.

Nothing renders a table or a userdata: that would be `__tostring`, which
is target code. They come back as a type and an address, with up to
`DBGKEYS` raw keys so a caller knows what it may walk into. The walk
itself is `dbg.get(pid, co, level, root, name, path)`, where `path` is
literal keys — `lib/dbg.lua`'s parser accepts `a.b`, `a[2]`, `a["k"]`
and nothing else, so there is no syntax for a call to reject.

## Which tool answers which question

| question | tool |
| --- | --- |
| what is on the machine | `ps`, `sys.wchan` |
| where is this proc now | `stack pid` |
| how did it get there | `trace pid` |
| what is this value, here | `dbg`, stopped at a breakpoint |
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

The debugger is a program rather than a word at the prompt, because it
holds state between commands:

    dbg run /bin/foo.lua     spawn it stopped before its first line
    dbg 7                    attach to a proc already running

`run` needs no capability — spawning the target *is* the right. A bare
pid needs the `dbg` grant, which `init.lua` hands the console and `dos`
inherits. `?` at the prompt lists the commands.

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
