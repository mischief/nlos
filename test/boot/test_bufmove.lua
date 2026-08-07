-- {__buf = b}: a buffer changes owner instead of being copied.
--
-- What is tested is the ownership rule, because that is what makes the
-- copy safe to skip: the sender is left with an empty handle, only
-- storage its holder alone owns may travel, and a send that fails
-- leaves the sender holding its bytes.

local sys = require("los.sys")
local buf = require("los.buf")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(27)

-- ---- it arrives, and the sender loses it ----

local rp = sys.newport()
local b = buf.new(64, 0x41)

b:copy(1, "moved")
sys.send(rp, { it = { __buf = b } })

tap.ok(not pcall(function() return #b end),
    "the sender's handle is empty after the send")
tap.is(tostring(b), "buf(given away)", "and says so")

local m = thread.recv(rp)

tap.is(type(m.it), "userdata", "the receiver got a buffer, not a string")
tap.is(m.it:sub(1, 5), "moved", "with the bytes in it")
tap.is(#m.it, 64, "and the whole length")

m.it:copy(1, "wrote")
tap.is(m.it:sub(1, 5), "wrote", "which the receiver may write")

-- ---- what may not travel ----

local whole = buf.new(32)
local v = whole:view(1, 8)

tap.ok(not pcall(sys.send, rp, { it = { __buf = v } }),
    "a view may not be given away: the bytes are not its own")
tap.ok(not pcall(sys.send, rp, { it = { __buf = whole } }),
    "nor a buffer with a view onto it")
tap.ok(not pcall(sys.send, rp, { it = { __buf = whole:ro() } }),
    "nor a read-only view")
tap.ok(not pcall(sys.send, rp, { it = { __buf = "a string" } }),
    "nor a string wearing the name")
tap.is(#whole, 32, "and the refused buffer is untouched")

-- a bare buffer still copies, arriving as a string
local plain = buf.new(4, 0x42)

sys.send(rp, { it = plain })
tap.is(thread.recv(rp).it, "BBBB", "a bare buffer still travels as bytes")
tap.is(#plain, 4, "leaving the sender's buffer alone")

-- ---- several in one message ----
--
-- the message is the list: a table can name as many buffers as it has
-- room for, which is what a writev would be for.

local one, two = buf.new(8, 0x31), buf.new(8, 0x32)

sys.send(rp, { parts = { { __buf = one }, { __buf = two } } })

local mm = thread.recv(rp)

tap.is(mm.parts[1]:str() .. mm.parts[2]:str(), "1111111122222222",
    "two buffers in one message both arrive")

-- ---- a refused send leaves the sender whole ----
--
-- MAXQUEUE counts transferred bytes, so filling the queue is what the
-- refusal has to come from.

local full = sys.newport()
local kept = buf.new(4096)
local n = 0

while sys.send(full, { it = { __buf = buf.new(4096) } }) do
	n = n + 1
	if n > 64 then break end
end
tap.ok(n <= 64, "transferred bytes count against the queue")
tap.ok(not sys.send(full, { it = { __buf = kept } }),
    "a send to a full queue is refused")
tap.is(#kept, 4096, "and the sender still has its buffer")

-- ---- the bytes are accounted, and follow the owner ----

local mine = select(4, sys.meminfo())
local given = buf.new(8192)
local held = select(4, sys.meminfo())

tap.ok(held >= mine + 8192, "a buffer counts against the proc that made it")
sys.send(rp, { it = { __buf = given } })
local after = select(4, sys.meminfo())

tap.ok(after <= held - 8192,
    "and stops counting against it once given away")

local back = thread.recv(rp)

tap.ok(select(4, sys.meminfo()) >= after + 8192,
    "counting against whoever received it: " .. #back.it)

-- ---- across procs, which is the case that could not be a copy ----
--
-- Two procs have two lua heaps. The bytes are in neither, so this is
-- the same handover as above and not a special case of it.

local from = sys.newport()
local out = buf.new(1024, 0x7a)

local pid, h = sys.spawn([[
	local a = ...
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)

	-- write to it to prove it is ours, and hand it back
	m.it:copy(1, "child")
	sys.send(a.reply.__right, { it = { __buf = m.it } })
]], { name = "bufchild", arg = { reply = { __right = from } } })

tap.ok(pid > 0, "a child to hand a buffer to")
tap.ok(sys.send(h, { it = { __buf = out } }), "the buffer goes to the child")
tap.ok(not pcall(function() return #out end), "and this proc no longer has it")

local rt = thread.recvtimeout(from, 5000)

tap.ok(rt ~= nil, "the child answered")
tap.is(rt and rt.it and rt.it:sub(1, 5), "child",
    "with the same bytes, written by the other proc")

-- ---- and in a spawn arg ----
--
-- the arg is the ordinary serializer, so a buffer travels there too:
-- a child can be born holding one, before it has run a line.

local born = buf.new(256, 0x71)

sys.spawn([[
	local a = ...
	local sys = require("los.sys")

	sys.send(a.reply.__right, { n = #a.it, first = a.it:sub(1, 1) })
]], { name = "bufborn", arg = { reply = { __right = from }, it = { __buf = born } } })

tap.ok(not pcall(function() return #born end),
    "a buffer in a spawn arg leaves the parent")

local bm = thread.recvtimeout(from, 5000)

tap.ok(bm and bm.n == 256 and bm.first == "q",
    "and the child is born holding it")
