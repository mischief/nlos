-- los.buf: bytes that can be written in place.
--
-- The point of the type is that changing a byte is not a new object, so
-- what is tested is that writes land, that the bounds hold, and that
-- the memory is accounted -- a buffer allocated outside the proc's
-- budget would be a hole in the budget.

local sys = require("los.sys")
local buf = require("los.buf")
local tap = require("tap")

tap.plan(44)

-- ---- what it is ----

local b = buf.new(16)

tap.is(#b, 16, "a buffer has a length")
tap.is(b:len(), 16, "and says so both ways")
tap.is(b:str(), string.rep("\0", 16), "new bytes are zero")
tap.is(tostring(b), "buf(16)", "tostring says what it is, not what is in it")

local f = buf.new(4, 0x41)

tap.is(f:str(), "AAAA", "new takes a fill byte")

-- ---- writing ----

b:copy(1, "hello")
tap.is(b:sub(1, 5), "hello", "copy puts a string in at a position")

b:copy(6, "WORLD", 2, 4)
tap.is(b:sub(1, 8), "helloORL", "and copies part of one: " .. b:sub(1, 8))

b:set(1, 72, 69)
tap.is(b:sub(1, 5), "HEllo", "set writes bytes by number")

local x, y = b:byte(1, 2)

tap.is(x, 72, "byte reads them back")
tap.is(y, 69, "including a run")

b:fill(0x2e, 1, 4)
tap.is(b:sub(1, 5), "....o", "fill covers a range")

-- the same buffer as its own source: memmove, not memcpy
local ov = buf.new(8)

ov:copy(1, "abcdefgh")
ov:copy(3, ov, 1, 6)
tap.is(ov:str(), "ababcdef", "a copy within one buffer overlaps safely: " ..
    ov:str())

-- ---- bounds ----

tap.ok(not pcall(function() b:copy(14, "toolong") end),
    "a copy past the end is refused")
tap.ok(not pcall(function() b:copy(0, "x") end),
    "a copy before the start is refused")
tap.ok(not pcall(function() b:set(17, 0) end),
    "a set past the end is refused")
tap.is(b:sub(20, 30), "", "a read past the end is empty, as string.sub is")
tap.is(b:sub(-3), b:sub(14, 16), "negative indices count from the end")

-- ---- read-only views ----

local ro = b:ro()

tap.is(ro:str(), b:str(), "a view sees the same bytes")
tap.ok(not pcall(function() ro:fill(0) end), "and cannot be written")
b:copy(1, "zz")
tap.is(ro:sub(1, 2), "zz", "a write through the buffer shows in the view")

local c = b:clone()

tap.is(c:str(), b:str(), "a clone has the same bytes")
c:copy(1, "..")
tap.is(b:sub(1, 2), "zz", "and is a copy, not a second name for them")

-- ---- accounting ----
--
-- Pooled bytes are charged to the proc, against the same cap as its lua
-- memory: a proc that can allocate outside its budget has no budget.

local before = select(4, sys.meminfo())
local big = buf.new(64 * 1024)
local after = select(4, sys.meminfo())

tap.ok(after - before >= 64 * 1024,
    ("a buffer is charged to the proc (%d -> %d)"):format(before, after))
tap.ok(sys.stats().buf_used >= 64 * 1024,
    "and counted for the machine: " .. tostring(sys.stats().buf_used))

big = nil
collectgarbage()
collectgarbage()

local freed = select(4, sys.meminfo())

tap.ok(freed <= before + 1024,
    ("and given back when it is collected (%d -> %d)"):format(after, freed))

-- a proc with a cap cannot allocate past it, however it asks
local pid = sys.spawn([[
	local buf = require("los.buf")
	local sys = require("los.sys")
	local a = ...

	-- far more than the cap below
	local ok = pcall(buf.new, 4 * 1024 * 1024)

	sys.send(a.__right, ok)
]], { name = "capped", mem = 256 * 1024,
    arg = { __right = sys.sendright(sys.SELF) } })

tap.ok(pid ~= nil, "a proc with a memory cap starts")

local thread = require("los.thread")
local got = thread.recvtimeout(sys.SELF, 5000)

tap.ok(got == false, "a buffer past the cap is refused rather than taken: " ..
    tostring(got))


-- ---- fields ----
--
-- The read side is the reason these exist: string.unpack reads a field
-- out of a string without allocating, and a buffer that had to make a
-- string per field would be the worse of the two.

local n = buf.new(8)

n:copy(1, "\1\2\3\4\5\6\7\8")
tap.is(n:u8(1), 1, "u8")
tap.is(n:u16le(1), 0x0201, "u16le")
tap.is(n:u16be(1), 0x0102, "u16be")
tap.is(n:u32le(1), 0x04030201, "u32le")
tap.is(n:u32be(1), 0x01020304, "u32be")
tap.is(n:u64le(1), 0x0807060504030201, "u64le")
tap.is(n:u64be(1), 0x0102030405060708, "u64be")

n:setu16le(1, 0xbeef)
tap.is(n:sub(1, 2), "\239\190", "setu16le writes low byte first")
n:setu16be(1, 0xbeef)
tap.is(n:sub(1, 2), "\190\239", "setu16be writes high byte first")
n:setu32le(3, 0xdeadbeef)
tap.is(n:u32le(3), 0xdeadbeef, "setu32le round trips")
n:setu64be(1, 0x0102030405060708)
tap.is(n:u64be(1), 0x0102030405060708, "setu64be round trips")

tap.ok(not pcall(function() return n:u32le(7) end),
    "a field that runs off the end is refused")

-- what the fat cache wants: a field read out of a sector with no
-- string made anywhere
local sec = buf.new(4096)

sec:setu16le(513, 0x1234)
tap.is(sec:u16le(513), 0x1234, "a field in the middle of a sector")

-- ---- views ----

local big = buf.new(64)

big:copy(1, string.rep("x", 32))
big:copy(33, string.rep("y", 32))

local v = big:view(33, 64)

tap.is(#v, 32, "a view is as long as its range")
tap.is(v:str(), string.rep("y", 32), "and sees that part of the buffer")
v:copy(1, "Y")
tap.is(big:sub(33, 33), "Y", "a write through a view lands in the buffer")

local rov = big:ro():view(1, 8)

tap.ok(not pcall(function() rov:fill(0) end),
    "a view of a read-only buffer is read-only")

tap.done()
