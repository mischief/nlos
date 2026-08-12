# Procs

A proc is an isolated `lua_State` plus one lua thread the chunk runs on.
Heap isolation is the point: two procs share no lua object, so nothing
either one does to its own values can be seen by the other.

`docs/scheduling.md` covers how procs are dispatched and preempted, and
`docs/debugging.md` covers reading one, corpses and the trace ring. This
file is what a proc is made of.

## Ceilings

`MAXPROCS` and `MAXPORTS` come from the platform's `param.h`, because
what is headroom on a machine with gigabytes is a large share of a
board's ram. Bodies are heap-allocated, so the static cost is one
pointer per slot, in `.bss`, whether or not a proc ever exists.

They are ceilings rather than reachable counts. Spawning until it fails
stops well short of `MAXPROCS`, because each proc is a `lua_State` and
the heap runs out long before the tables do. Dispatch and wakeups do not
scan, so a round trip costs the same at the bottom and the top of the
range — which is exactly why a small platform can pick a small number
and lose nothing but headroom. Going much further wants a two-level
index rather than a flat one, which would add an indirection to every
serialize.

`MAXRIGHTS` is what bounds a supervisor. `sys.spawn` hands the parent a
right per child, so holding them caps the tree unless the parent closes
each handle and tracks its children by pid through `sys.monitor`. Only
the first `NRIGHTS_INLINE` cost anything per proc.

## States

`BROKE` and `STOPPED` are described in `docs/debugging.md`, which is
where they matter.

`HATCHING` is a proc that exists and has never run — `proc_new` made it,
`proc_launch` has not. It is distinct from `BLOCKED` because `BLOCKED`
means "waiting on a port" and carries a waiter naming that port. A
hatching proc waits on its creator and is on no port at all, and the
wake paths test for `BLOCKED`, so nothing but its creator can make one
runnable.

The state exists because a proc is not finished when `proc_new` returns.
The caller still has to install the spawn argument, a driver's device
right, or the boot proc's grants. A second cpu that dispatched it inside
that window would resume a half-built proc and race its creator for its
stack.

`PRIV_BOOT` is proc 0 and nothing else. It is not a device capability
like the rest of the `PRIV_` values — it means raw ESP access reaches
this proc, which is true only of the proc the kernel starts itself, and
is what lets it build the root namespace every other proc inherits.

## Inherited budgets

Instruction budget, memory cap and port cap are inherited, and may only
be asked downward, so a child is never less contained than its parent.
Absent means the parent's rather than the machine default, and a larger
request is clamped rather than refused: refusing would make a
supervisor's own containment its children's problem to know about, where
clamping lets the same code run either way.

They are inherited rather than divided. A parent held to eight ports may
spawn two children of eight each. What a cap bounds is any one proc,
which is what makes a runaway loop cost its own proc first; dividing
would bound a whole tree, and needs an accounting of who spawned whom
that nothing here keeps.

A port cap is counted as what a proc *holds* rather than what it made,
which is unix's rule for `RLIMIT_NOFILE` and needs no record of who
created what. It is also the honest measure: a port nobody holds a right
to is freed, so what fills the table is holding, and a right handed to
another proc becomes that proc's cost. It counts receive rights, because
those are one per port in the ordinary case where send rights are not.

The cap exists because ports are a machine-wide table, so one proc
looping on `sys.newport` starves every other — and it need not be its
own loop. A server that mints a port per session on demand spends its
budget on behalf of whichever client asked. That is the shape a per-proc
cap answers and a per-server quota cannot, because a port carries no
sender identity and a server cannot tell whose request it is holding.

## Confinement

Every proc but proc 0 loses the file half of `io`, and `loadfile` and
`dofile` with it. `lib/nsio.lua` puts `io.open` back over the proc's
namespace, so a proc reaches exactly what was mounted for it and a proc
given no namespace cannot open a file at all. That is the point: the
namespace stops being advisory and becomes the boundary.

Removing the reference is the mechanism, not a check inside it. A check
lives in every proc's C surface and is one bug away from everything; a
function that is not there cannot be called wrong. The console half —
`io.write`, `io.read`, `print`, stdout and stderr — stays, because it is
a device rather than a file.

The stripping has to be possible from two places, because `io` is loaded
lazily through a metatable on `_G` and lua re-runs the opener whenever
`package.loaded` is falsy — which an unprivileged proc can arrange,
handing itself a fresh working `io.open`. So the lazy loader re-strips.

`debug.sethook` goes for a related reason: it would be a way out of the
instruction budget. Bytecode loading goes because a crafted chunk is not
bound by the verifier lua applies to source.

Proc 0 keeps all of it, because it is where raw ESP access reaches and
where the root namespace is built. It has no namespace to be confined to
until it has made one.

## Where a proc's lua heap lives

The arrangement follows `NCPU`:

| build | arrangement | why no lock |
| --- | --- | --- |
| `NCPU == 1` | one heap for the machine | one cpu |
| `NCPU > 1` | one heap per proc | each touched only by the cpu running that proc |

A shared heap is the cheaper one. A proc's lua heap is small, so the
tail of its last chunk is paid once for the machine instead of once per
proc, and one proc reusing another's freed blocks lowers total
fragmentation rather than raising it. Per-proc heaps cost on the order
of a quarter more mapped memory, and heap waste roughly doubles. What
lua itself asks for is identical either way — the whole difference is
chunk tails.

A second cpu changes the answer. A shared heap needs a lock taken on
every lua allocation, which is the most frequent thing this kernel does.
The choice is a fraction more memory, or serializing every cpu on the
hottest path in the system, and that is not a close call. A per-proc
heap needs no lock of its own because a proc runs on one cpu at a time
and its heap is touched only while it is running. The chunk source
underneath is shared and locked, but a heap asks it for another chunk
only a handful of times in a proc's life.

Containment does not depend on either arrangement: `mem_used` and
`mem_limit` are counted per proc in `kalloc`.

A proc that allocates hugely and dies returns those chunks either way.
Per-proc, `destroy` returns the whole heap at once. Shared, the blocks
dissolve into the common free lists and `luaheap_reclaim` gathers up
whatever chunks came out empty — which recovers less, because a dead
proc's blocks share chunks with whatever else was allocating at the
time, and a chunk with one survivor in it stays.

**The trap:** this tests `NCPU`, not `platform_ncpu()`. The runtime
count is not known when the first proc is made — AP startup deliberately
runs after it, since an AP started before there is a proc falls straight
out of the dispatch loop and parks for good. A runtime test would hand
the boot proc a shared heap and every later proc its own. `NCPU` is what
the build can have, which is the question that stays true for the life of
the machine. The cost is that a multiprocessor image booted with one cpu
keeps per-proc heaps, and that is a guest with memory to spare.

Chunks come from the platform's pool. The machine loses about a quarter
again on top of every byte the heap believes it mapped, and `kheap_stats`
cannot see it, because the pool's metadata is not ours. Taking whole
pages instead looks like the obvious fix and measures substantially
worse, flat across chunk sizes: the pool reuses pages it already holds
better than we ask for new ones. Do not retry it without measuring both.

## Pooled bytes

`los.buf` takes its storage from the chunk source rather than a proc's
lua heap, so `kalloc` never sees it. It is charged against the same cap
anyway: a proc that can allocate outside its budget has no budget.
`buf_used` counts the same bytes again on their own, because memory that
is not in the numbers is memory nobody finds.

Those bytes also pace the collector. A proc that only receives buffers
holds megabytes of them while its lua heap looks idle, so the step is
owed against them too — taken at the dispatch point, where nothing is
held, since a step under a bucket could run a finalizer there.

## Measuring

`sys.meminfo()` reports a proc's own live bytes and its share of pooled
buffers. `sys.stats().mem` reports the machine's mapped total and waste.
To compare heap arrangements, run tens of idle procs and read the mapped
total per proc — the difference is chunk tails, so it shows up there and
not in lua's live bytes.
