# where the memory goes

What holds memory on this machine, how to ask it, and what the answers
mean. `src/luaheap.c` is the allocator; this is the view from outside
it.

The figures here are an esp32's, on a T-Deck with PSRAM. The shape
holds everywhere -- the layers and the questions are the same -- but
where the chunks come from and what they cost is the platform's, and
only this one has been measured. See the last section for what that
leaves open.

## the layers, outermost first

**The chunk pool.** `platform_chunk_alloc` is where everything
ultimately comes from, and each platform answers it differently. On
esp32 with PSRAM it names `MALLOC_CAP_SPIRAM` itself, so the pool is
PSRAM and the size of a request does not decide which memory it lands
in.

**The lua heap**, carved from that pool in chunks. One heap for the
machine, shared by every `lua_State`. It hands out blocks in size
classes and never gives a chunk back until every block in it is free.

**Per-proc accounting** over that one heap: `mem_used` and `mem_peak`
are what a proc asked for, not what the machine holds to serve it.

**`los.buf`**, also from the chunk pool but not from a lua heap. A
framebuffer image is here, not in any proc's lua figure.

**The C heap** for everything else: port messages, payload copies, the
loadfile buffer.

## two kinds of memory, on esp32

A board with PSRAM has two pools and they are not interchangeable.

**Internal SRAM is the scarce one.** On an S3 the usable part is
Internal SRAM 1, which the TRM describes as addressed through the data
bus or the instruction bus in the same order -- so IRAM code and
statics come out of one pool, which IDF's size report calls DIRAM. It
is a few hundred KB against 8MB of PSRAM, roughly two thirds of it is
gone to IDF before we boot, and no setting buys more. The instruction
and data caches are carved from Internal SRAM 0 and 2, which have no
other use, so cache sizing does not compete with this.

**So a static array is spent from the scarce pool.** Anything sized in
KB should come from `platform_chunk_alloc`, which answers from PSRAM
where the machine has any: the kernel's transcript is a pointer for
this reason, with a small static one covering the lines logged before
there is an allocator to ask.

**But PSRAM disappears during a flash write.** The cache is turned off
for the duration, so anything touched in that window must be internal:
ISR code, and the stack of any task that might run. IDF checks the
second with `esp_task_stack_is_sane_cache_disabled` and aborts, which
is what a task given a PSRAM stack dies of the first time `fatsrv`
writes.

**Where it went**, for the static half: `idf.py size` for the DIRAM
total, `size-components` for which archive owns it, and
`nm --size-sort -S libmain.a` for the objects inside ours. The
difference between what that reports and what `stats` says is free is
runtime allocation -- driver buffers, task stacks, the radio.

## reading the stats line

`stats` at the prompt, or the bare word in the repl. The shape of it,
with one board's figures standing in for whatever yours says:

	procs=22 ports=86 heap=5614K lua=3174K/4720K (1.49x)
	mem=39K/276K free max=38K chunks=2802K/8180K free max=2752K buf=278K

`lua=live/mapped` is the heap: what the states between them asked for,
over what the machine holds to serve it. The ratio is the overhead the
allocator exists to bound.

Three traps in that line:

- `heap=` counts every C allocation including the lua heap's chunks,
  so it is **not additive** with `lua=`.
- `buf=` is in neither `lua=` nor the per-proc figures. A machine short
  of memory with a healthy `lua=` is usually holding images.
- **`mem=` is not where a lua object goes on a board with PSRAM.** It
  is internal sram, and a browsing T-Deck can show tens of K free there
  while `chunks=` has hundreds. Budget against `chunkavail`, never
  `memavail`. The `chunks=` field appears only where the two pools
  differ, which is what says a platform has this trap at all.

`max` is the largest single free run. Free bytes scattered below what a
chunk costs buy nothing, and a `font.render` that cannot allocate is
how that shows.

## asking

	ps                     every proc's live and peak
	sys.meminfo(pid)       one proc: used, peak, limit, buf
	sys.stats()            the machine, as above
	sys.reclaim()          hand back what is held and unused

`collectgarbage("count")` is machine-wide and says nothing about a
proc, because the heap is shared. A delta from it measures a structure
only when nothing else is running.

Garbage per operation, which a peak cannot show:

	collectgarbage()
	collectgarbage("stop")
	local before = collectgarbage("count") * 1024
	for i = 1, 100 do thing() end
	local per = (collectgarbage("count") * 1024 - before) / 100
	collectgarbage("restart")

`test/luaheap_bench.c` runs a workload through the allocator on a host
and reports where the waste is: rounding, headers, and space inside
chunks that nothing is using.

## what things cost

Figures move, so ask rather than quote. What to ask, and of what:

	a proc, before it does anything    ps, on a fresh boot
	the machine, by object type        sys.heapstat()
	one page of a reader               bin/web.lua's own proc in ps
	where the allocator's waste is     meson test luaheap-bench
	what a dropped page hands back     the same, its last section
	garbage per operation              the recipe above

Two costs are structural rather than measured, and will hold as long as
the code does:

- A run in `lib/doc.lua` is two array slots. As a table of its own it
  would be a table header, a hash part and a pointer as well, which is
  what `M.run`'s comment is about.
- A `gmatch` state is one allocation per call, sized by
  `LUA_MAXCAPTURES` and the pointer width -- `sizeof(GMatchState)` in
  `lua/lstrlib.c`, whose `MatchState` carries `capture[LUA_MAXCAPTURES]`.
  `coreg.h` sets that constant, and `lib/html.lua`'s `M.attrs` has the
  comment on why it matters.

`lib/html.lua`'s `M.BLOCKCOST` is what a block of a parsed page costs.
It is a constant a caller budgets with, so it is in the code with the
bound it feeds; check it against `ps` if a page ever costs more than
it says.

## the rules

**Ask for memory back.** A chunk returns to the pool only when every
block in it is free, and nothing looks for that on its own:
`luaheap_reclaim` runs when a proc exits or when an allocation has
already failed, and nowhere else. A program that drops something large
should call `sys.reclaim()` after collecting. `bin/webui.lua` does it
where it replaces a page.

**One survivor holds a whole chunk.** That is why `LUAHEAP_CHUNK` is
smaller on esp32 than elsewhere: dense survivors hand back nothing at a
large chunk size. `luaheap-bench` reports the figure for whatever size
a build uses, at three survivor densities, and that report is what a
chunk size should be chosen by.

**Bound the work, not the result.** A page, a message or a file from
anywhere is unbounded input. Take a fraction of what is free, ask for
it before each piece of work rather than once at startup, and say when
a bound cut something short. A bound picked on a 512MB host is not a
bound.

**A table per item is the item's cost, twice over.** Parallel arrays
cost two slots where a table costs a header, a hash part and a
pointer. It is the difference between a page that fits and one that
does not.

**`gmatch` allocates a fixed-size state per call**, sized by
`LUA_MAXCAPTURES` rather than by the pattern, and large enough that a
few per item dominate what a parser allocates at all. `find` keeps its
state on the C stack. `M.attrs` in `lib/html.lua` and `M.dotseg` in
`lib/url.lua` are what one looks like rewritten.

**One heap for the machine is a choice, not a consequence.**
`SHARED_LUAHEAP` decides it, and sharing costs a lock on every
allocation -- a compiler barrier where `NCPU` is 1. Per-proc heaps pay
each heap's chunk tails instead, which on a board is megabytes and can
put the largest free block below what `dio` wants to start an app.
Measure `chunks ... free max` at rest before changing it.

**Precompute what is expensive, not what is repeated.** See
[graphics.md](graphics.md), which has the panel side of all of this.

## measured, and left alone

**Size classes.** `luaheap-bench` breaks the waste into rounding,
headers and space inside chunks, and prints the request profile the
classes were chosen from. Rounding is the small term; the space inside
chunks is the large one, and only a reclaim or a compacting collector
recovers that. Before retuning, read that report: the sizes that round
badly round badly because they are not multiples of `ALIGN`, and no
class can help them.

**Chunk size, for its own sake.** Peak `mapped/live` barely moves
across a sweep from 1K to 64K. Release granularity is the reason to
choose a size, not overhead -- which is what the bench's last section
measures.

**Chunk size on the other platforms.** `LUAHEAP_CHUNK` is set per
platform in `src/platform/*/param.h`, and each comment says what its
number was chosen against. esp32's is release granularity, for the
reason above. The rest were chosen against the chunk source's own
per-call cost -- `AllocatePool`'s, measured and recorded in
`luaheap.c` -- from before anything asked what a dropped page hands
back. Whether release granularity is worth more than that per-call
cost there is **not measured**, and neither is their
`platform_chunk_alloc`: only esp32's is characterised here. A machine
with room to spare may not care.

**`LUA_32BITS`.** Halves `TValue` on a 32-bit target, and makes
`lua_Number` a `float`, which an S3 has an FPU for and a `double` it
does not. Measured on a T-Deck: less live lua, and faster at integers,
tables and floats alike, the floats by much the most. Reproduce by
setting it in `lua/luaconf.h`, flashing, and reading `stats` on a
fresh boot beside the arithmetic loops it is worth timing.

Not adopted, for two reasons that are properties of the code rather
than figures:

- `lua_Integer` becomes 32-bit, and the protocols here carry 8-byte
  fields: 9P's qid and file length in `lib/ninep.lua`, protobuf
  varints, gefs block numbers. `string.unpack` on `I8` raises where it
  does not fit. Count them with
  `grep -rn 'I8' lib task bin --include=*.lua`.
- `lib/crypto/bignum.lua` multiplies 32-bit limbs into 64-bit
  products, which would overflow **silently**. Its own comment names
  the assumption. Smaller limbs would fix it, at roughly four times the
  multiplies.

The float half alone carries none of that risk and most of the speed,
but `lua/luaconf.h` defines the number types unconditionally -- unlike
the knobs it does guard with `#if !defined` -- so a `-D` cannot reach
them and adopting either means patching the submodule.
