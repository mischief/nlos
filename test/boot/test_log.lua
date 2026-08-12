-- the kernel's transcript: sys.log, sys.dmesg, sys.loginfo.
--
-- The cursor is the point. A reader that keeps the one it was handed
-- sees every byte written after it, or is told how many it missed.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(33)

local LINE = 1024		-- LOGLINE in src/kernel.c
local CHUNK = 2048		-- LOGCHUNK, the most one call copies

-- everything from here on, including the kernel's own boot lines.
local seq0, size, oldest0 = sys.loginfo()

tap.ok(seq0 > 0, "the kernel logged its own boot")
tap.ok(size >= 8192, "the ring has a size")
tap.ok(oldest0 <= seq0, "and a window inside it")

-- ---- a line goes in ----
sys.log("hello from the test")

local data, cur, dropped = sys.dmesg(seq0)

tap.ok(data:find("hello from the test", 1, true) ~= nil, "the line is there")
tap.is(dropped, 0, "nothing dropped")
tap.is(cur, seq0 + #data, "the cursor advances by what came back")
tap.ok(data:sub(-1) == "\n", "a line is terminated")

-- the tag is the proc's name, and it comes from the kernel: a proc
-- cannot claim to be another one.
tap.ok(data:find(sys.name(sys.self()) .. ": hello", 1, true) ~= nil,
    "tagged with this proc's name")
tap.ok(data:find("^%[%s*%d+%.%d%d%d%] ") ~= nil, "and stamped")

-- ---- the cursor is a cursor ----
local again, cur2 = sys.dmesg(cur)

tap.is(again, "", "reading from the cursor again gives nothing")
tap.is(cur2, cur, "and does not move it")

sys.log("second")
data, cur = sys.dmesg(cur)

tap.ok(data:find("second", 1, true) ~= nil, "only what arrived after it")
tap.ok(data:find("hello", 1, true) == nil, "and nothing from before")

-- ---- formatting ----
local at = sys.loginfo()

sys.log("%s %d %04x", "fmt", 7, 255)
data = sys.dmesg(at)

tap.ok(data:find("fmt 7 00ff", 1, true) ~= nil, "string.format, as lua means it")

-- a single argument is used as-is, so a line holding a percent sign is
-- not a format waiting for arguments it does not have
at = sys.loginfo()
sys.log("100% sure, %d%s")
data = sys.dmesg(at)

tap.ok(data:find("100% sure, %d%s", 1, true) ~= nil, "one argument is not a format")

-- a bad format is data, not a fatal error: this proc must survive it
at = sys.loginfo()
sys.log("%d", {})
data = sys.dmesg(at)

tap.ok(sys.loginfo() > at, "a bad format still writes a line")
tap.ok(data:find("%%d") ~= nil or data:find("%d", 1, true) ~= nil,
    "falling back to the format itself")

-- the fallback prints the caller's format after the failed call has
-- consumed it, so what anchors that string matters. Collecting between
-- the failures is what would show it going unanchored.
at = sys.loginfo()
for i = 1, 50 do
	collectgarbage("step")
	sys.log("unanchored %d " .. i, {})
end
data = sys.dmesg(sys.loginfo() - 64)

tap.ok(data:find("unanchored %d 50", 1, true) ~= nil,
    "the format survives its own failed call")

-- ---- the line limit ----
at = sys.loginfo()
sys.log(("a"):rep(LINE * 3))

local grew = sys.loginfo() - at

tap.ok(grew <= LINE, "a line past the limit is truncated to it")
data = sys.dmesg(at)
tap.is(data:sub(-1), "\n", "and still ends a line")

-- ---- one call is bounded ----
at = sys.loginfo()
for i = 1, 20 do
	sys.log("filler %d, and some more text to make the line longer", i)
end

data, cur = sys.dmesg(at)

tap.ok(#data <= CHUNK, "one call copies a bounded chunk")
tap.ok(#data > 0, "and copies something")
tap.is(cur, at + #data, "the cursor says where to continue")

-- draining with the cursor reaches the end
local endseq = sys.loginfo()
local guard = 0

while cur < endseq and guard < 100 do
	local more

	more, cur = sys.dmesg(cur)
	if more == "" then
		break
	end
	guard = guard + 1
end
tap.is(cur, endseq, "and the cursor reaches the end by looping")

-- ---- max ----
data = sys.dmesg(at, 10)

tap.is(#data, 10, "max bounds one call")
tap.is(select(2, sys.dmesg(at, 10)), at + 10, "the cursor with it")

-- ---- wrapping ----
--
-- Past the ring's size the oldest bytes are gone, and a reader holding
-- a cursor from before that is told so rather than skipped silently.
local stale = sys.loginfo()
local filler = ("y"):rep(LINE - 64)

for _ = 1, (size // LINE) + 4 do
	sys.log("%s", filler)
end

local seq, _, oldest, lost = sys.loginfo()

tap.ok(oldest > stale, "the window has moved past the old cursor")
tap.is(seq - oldest, size, "and is exactly the ring")
tap.ok(lost > 0, "the kernel counts what it overwrote")

data, cur, dropped = sys.dmesg(stale)

tap.is(dropped, oldest - stale, "a stale cursor is told what it lost")
tap.ok(cur > oldest, "and is moved to the start of the window")

-- ---- a reader that asks for nonsense ----
tap.is((sys.dmesg(seq + 1000)), "", "a cursor past the end reads nothing")
tap.ok(sys.loginfo() > 0, "and the ring still answers")
