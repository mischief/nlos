/* per-platform kernel table sizes. see kernel.c for what they cost and
 * why they are headroom rather than reachable counts.
 *
 * the board is where these stop being free. procv and portv are .bss,
 * so they are spent before the first proc exists, and .bss lands in
 * internal sram -- the scarce pool -- not in the 8MB of psram that
 * backs the heaps. at the shared 4096/32768 they measured 144KB
 * (portv 0x20000, procv 0x4000) against the 242KB of internal sram
 * this chip reports at heap_init: 37% of it, for tables a handheld
 * will not fill.
 *
 * 128 and 2048 cost 8.5KB. that is not a limit anyone will reach here:
 * a proc is a lua_State, and even with psram behind it the heap gives
 * out first -- the same argument that makes 4096 headroom elsewhere
 * makes 128 headroom here, at a sixteenth of the price.
 *
 * ports are kept well above procs on purpose. they are the plentiful
 * thing: every proc has its own receive port before it asks for
 * anything, and a server hands out one per client.
 */
#define MAXPROCS	128
#define MAXPORTS	2048

/* luaheap's granularity, for the same reason and at the same scale.
 *
 * The shared heap asks its source for one chunk at a time and carves
 * small blocks out of it, so a chunk is the smallest thing that can be
 * held on behalf of a proc that only needed a few hundred bytes. At the
 * 8KB used elsewhere that is 8KB of internal sram committed to whoever
 * allocated first, on a machine with 386KB in total.
 *
 * The large-block cache costs more: four blocks per size class
 * across 128 classes is unbounded in any way that matters here.
 * Measured before this: 113KB sitting unused inside the heap while
 * malloc had 32KB left and a proc was dying of "not enough memory".
 * One per class still spares the repeated same-size request -- which is
 * what the cache is for -- without the heap becoming where the memory
 * went.
 */
#include <sdkconfig.h>

#if CONFIG_SPIRAM

/* PSRAM is named by platform_chunk_alloc, so ALWAYSINTERNAL's
 * threshold decides nothing here. Small because a chunk returns only
 * when every block in it is free: one survivor per twenty blocks gives
 * back 65% of a dropped page at 2K, 13% at 8K.
 */
#define LUAHEAP_CHUNK		(2 * 1024)
#define LUAHEAP_LARGE_CACHED	4

#else

#define LUAHEAP_CHUNK		(2 * 1024)
#define LUAHEAP_LARGE_CACHED	1

#endif

/* Lua's gc pause: how far the heap may grow past live before the next
 * cycle, as a percentage. Memory traded for cpu, at a steep rate down
 * here -- collector work per byte allocated goes as 100/(pause-100),
 * so below about 200 a proc pays several times over for each byte.
 * `stats` at the prompt says what this board actually holds.
 */
#define GCPAUSE		300

/* the scheduler's slice, longer here than the 2ms the other platforms
 * take.
 *
 * A lap of kernel_run measured 130us on this board -- a slow core with
 * its lua heap in psram, pumping a keyboard and a serial port each time
 * round. At 2ms that is 6% of the cpu spent switching: 2000000 lua
 * iterations took 2471ms at 2ms and 2325ms at 20ms, which is 1119
 * fewer laps for 146ms.
 *
 * 10ms takes most of that back and costs nothing the machine did not
 * already cost. expire_timers runs once per lap, so this is the longest
 * a busy proc can make a timer late -- and an idle one already waits
 * for a 10ms tick that backs off to 15ms, so the worst case is
 * unchanged.
 */
#define QUANTUM_MS	10
