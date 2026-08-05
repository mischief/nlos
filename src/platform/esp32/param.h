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
