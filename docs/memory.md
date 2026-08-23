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

## reading the stats line

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
  is internal sram: a T-Deck browsing shows 39K free there and 800K in
  `chunks=`. Budget against `chunkavail`, never `memavail`. The
  `chunks=` field appears only where the two pools differ, which is
  what says a platform has this trap at all.

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

	a proc, before it does anything     ~500K
	a block of a parsed page            ~650 bytes, whatever it holds
	a run as two array slots            ~32 bytes
	a run as a table of its own         ~120 bytes before its text
	a gmatch state                      608 bytes at 64-bit, 308 at 32
	Proto, machine-wide                 about 44% of everything live

## the rules

**Ask for memory back.** A chunk returns to the pool only when every
block in it is free, and nothing looks for that on its own: the heap
keeps its high water mark until a proc exits or an allocation has
already failed. A program that drops something large should call
`sys.reclaim()` after collecting. On a dropped page that is 500K.

**One survivor holds a whole chunk**, which is why esp32 uses 2K
chunks: with a survivor every twenty blocks, 2K gives back 65% of a
dropped page and 8K gives 13%. Other platforms are still at 8K, chosen
against a different cost -- see below.

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
`LUA_MAXCAPTURES` rather than by the pattern. Three of them per tag was
a third of everything parsing a page allocated. `find` keeps its state
on the C stack; prefer it in a loop over anything hot.

**Precompute what is expensive, not what is repeated.** See
[graphics.md](graphics.md), which has the panel side of all of this.

## measured, and left alone

**Size classes.** Rounding is 3.4% of live on a 64-bit host and 5.6% on
the board. The waste is free space inside chunks, which only a reclaim
or a compacting collector recovers. Retuning the classes wins little;
the sizes that round badly are 12 and 44 bytes, and neither can be
helped at 8-byte alignment.

**Chunk size, for its own sake.** Peak `mapped/live` barely moves
across 1K to 64K -- 1.23 to 1.26. Release granularity is the reason to
choose one, not overhead.

**Chunk size on the other platforms.** esp32 is 2K for the reason
above; efi, microvm, hosted and wasm are all 8K, and that number was
chosen against the chunk source's own per-call cost -- 92 bytes per
`AllocatePool`, measured on efi -- rather than against how much comes
back when a page is dropped. Whether release granularity is worth more
than that per-call cost on those platforms is **not measured**. The
same goes for their `platform_chunk_alloc`: only esp32's is
characterised here, and a machine with room to spare may not care.

**`LUA_32BITS`.** Halves `TValue` on a 32-bit target and would put
float math on the S3's FPU. Measured on the board: 9% less live lua,
15-19% faster integer and table work, 46% faster float. Not adopted:
`lua_Integer` becomes 32-bit, and 96 `pack`/`unpack` sites use 8-byte
fields -- 9P's qid and file lengths, protobuf varints, gefs block
numbers. `lib/crypto/bignum.lua` multiplies 32-bit limbs into 64-bit
products, which would overflow **silently**. The float half alone is
worth 33-41% with none of that risk, but `luaconf.h` defines the
number types unconditionally, so neither can be set without patching
the submodule.
