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

It is safe on anything, including a wedged proc, because the machine is
cooperative and single-threaded: every proc but the caller is suspended
between resumes, so there is no moment at which a stack is half-built.

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
oldest first, as `{source=, line=, thread=}`. `entries` of 0 frees it.
The ring is freed with the proc's state, not at its death, so a corpse
answers "how did it get here" for as long as it answers "where".

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

## Where to find it

From the lua repl (`init.lua` wires these as globals):

    ps                  the process table, printed live
    stats               ports, heap, lua memory, corpses
    stack(pid)          every coroutine of that proc
    trace(pid)          its ring, runs of one line collapsed

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
