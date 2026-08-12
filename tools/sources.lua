-- The source lists, in the one place both build systems can read them.
--
-- meson builds efi and microvm; ESP-IDF's cmake builds esp32, because
-- reproducing IDF's link (generated linker fragments, section placement,
-- keep-lists, init arrays, the app descriptor, the bootloader) in a
-- meson cross file is a bet that loses on every IDF version bump. Two
-- build systems is the honest answer, and two source lists is what makes
-- that answer rot: a file added to one and not the other breaks a
-- platform nobody is looking at. That already happened once, when a
-- conflict-free rebase broke the microvm link.
--
-- So the lists live here and both sides ask. Prints one repo-relative
-- path per line, which is all either side needs:
--
--     meson:  run_command(lua_interp, 'tools/sources.lua', 'kernel')
--     cmake:  execute_process(COMMAND lua tools/sources.lua kernel)
--
-- Groups are only those genuinely shared. A platform's own directory
-- stays in that platform's build file, where the person editing it is
-- already looking.

local groups = {}

-- arch-blind and firmware-blind: every platform compiles exactly these.
-- The seam under them is src/platform.h plus the per-platform include
-- dir, so nothing here knows which machine it is on.
groups.kernel = {
	"src/native_glue.c",
	"src/gefs_native.c",
	"src/debug.c",
	"src/dirs.c",
	"src/inet.c",
	"src/ninep.c",
	"src/crc.c",
	"src/buf.c",
	"src/font.c",
	"src/kernel.c",
	"src/serialize.c",
	"src/thread.c",
	"src/linit.c",
	"src/luaheap.c",
}

-- our freestanding libc. softmath.c is NOT here: it is added per-arch by
-- the arches that need it (aarch64 and riscv64), which is a decision
-- about the machine rather than about the library.
groups.libc = {
	"src/libc/locale.c",
	"src/libc/math.c",
	"src/libc/stdio.c",
	"src/libc/stdlib.c",
	"src/libc/string.c",
	"src/libc/time.c",
	"src/libc/vsnprintf.c",
}

-- vanilla lua. lua.c and luac.c are programs with their own main();
-- loslib.c is left out because there is no os to bind, and lua's own
-- linit.c is replaced by src/linit.c, which is what strips io and
-- friends per proc. liolib and loadlib ARE built -- src/linit.c
-- registers them, and lib/nsio.lua puts io.open back over a namespace.
groups.lua = {
	"lua/lapi.c", "lua/lauxlib.c", "lua/lbaselib.c", "lua/lcode.c",
	"lua/lcorolib.c", "lua/lctype.c", "lua/ldblib.c", "lua/ldebug.c",
	"lua/ldo.c", "lua/ldump.c", "lua/lfunc.c", "lua/lgc.c",
	"lua/liolib.c", "lua/llex.c", "lua/lmathlib.c", "lua/lmem.c",
	"lua/loadlib.c", "lua/lobject.c", "lua/lopcodes.c",
	"lua/lparser.c", "lua/lstate.c", "lua/lstring.c", "lua/lstrlib.c",
	"lua/ltable.c", "lua/ltablib.c", "lua/ltm.c", "lua/lundump.c",
	"lua/lutf8lib.c", "lua/lvm.c", "lua/lzio.c",
}

local which = ...

if not which or not groups[which] then
	local names = {}

	for k in pairs(groups) do names[#names + 1] = k end
	table.sort(names)
	io.stderr:write("usage: sources.lua <" .. table.concat(names, "|") .. ">\n")
	os.exit(1)
end

print(table.concat(groups[which], "\n"))
