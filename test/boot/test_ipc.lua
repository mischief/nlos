-- serializer round trips, right transfer, refusal of the untransferable

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(18)

-- echo child reflects whatever it gets back through a reply right
local _, w = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	while true do
		local m = thread.recv(sys.SELF)
		if m.stop then break end
		sys.send(m.reply.__right, m.value)
	end
]])

local rp = sys.newport()

local function roundtrip(v)
	sys.send(w, { value = v, reply = { __right = rp } })
	return thread.recv(rp)
end

tap.is(roundtrip(nil), nil, "nil round trip")
tap.is(roundtrip(true), true, "boolean round trip")
tap.is(roundtrip(42), 42, "integer round trip")
tap.is(roundtrip(2.5), 2.5, "float round trip")
tap.is(roundtrip("hi\0there"), "hi\0there", "binary string round trip")

local t = roundtrip({ a = 1, nested = { b = "two", c = { 3 } } })
tap.ok(t.a == 1 and t.nested.b == "two" and t.nested.c[1] == 3,
    "nested table round trip")

-- deep copy: receiver mutations invisible (fresh table each recv)
local t2 = roundtrip({ list = { 1, 2, 3 } })
t2.list[1] = 99
local t3 = roundtrip({ list = { 1, 2, 3 } })
tap.is(t3.list[1], 1, "messages are copies, not references")

-- functions refuse to travel
local ok, err = pcall(sys.send, w, { f = function() end })
tap.ok(not ok and err:find("unserializable") ~= nil,
    "function refused with error")

-- a payload over half of MAXMSG, carried in the shape the framebuffer
-- sends: a nested table beside the bytes. api_send pre-sizes the write
-- buffer from a hint that deliberately does not agree with the
-- serializer, and the hint counts a nested table as one small value
-- rather than walking it -- so the serializer runs past the pre-sized
-- cap, and doubling from an arbitrary cap overshoots the 64KiB limit
-- for a message nowhere near it. Refusing on the overshoot rather than
-- on the requirement lost six of a smiley's seven bands.
--
-- the nesting is the part that matters: a flat table of the same size
-- stays under its own hint and proves nothing.
local BIG = string.rep("x", 40000)
local big = roundtrip({ op = "load", r = { x = 0, y = 0, w = 200, h = 50 },
    data = BIG })

tap.ok(type(big) == "table" and big.data == BIG and big.r.w == 200,
    "a payload past half of MAXMSG survives the round trip")

-- and the limit itself still holds, so the fix is a correction to
-- where the test is made and not its removal
local toobig = pcall(sys.send, w, { data = string.rep("x", 70000) })

tap.ok(not toobig, "a payload genuinely over MAXMSG is still refused")

-- right transfer chain: pass a fresh recv right THROUGH the echo,
-- then use it
local chain = sys.newport()
local got = roundtrip({ carried = { __right = chain } })
tap.ok(type(got.carried) == "table" and got.carried.__right ~= nil,
    "right survived a proc hop")

-- ---- blocking twice is refused ----
--
-- sys.block yields to whoever resumed the coroutine it is called from.
-- At the top level of a proc that is the kernel, which is the contract.
-- Inside a coroutine it is that coroutine's resumer -- a thread
-- scheduler -- so the kernel has marked the proc BLOCKED and taken it
-- off the run queue while the proc carries on running. The next block
-- then hangs a second waiter for one proc on a port, and wake_receivers
-- walks a waiter that wait_clear already freed. Refuse the second one
-- instead, where the mistake is, rather than faulting later.
--
-- los.thread's park() and recv() pick park over block via inthread(),
-- so ordinary threaded code never reaches this. Requiring that module
-- under a name other than "los.thread" gets a second scheduler with its
-- own _current, which is one way to arrive here.
local pa, pb = sys.newport(), sys.newport()
local blocked = coroutine.create(function() sys.block(pa) end)
local again = coroutine.create(function() sys.block(pb) end)

tap.ok(coroutine.resume(blocked),
    "sys.block inside a coroutine yields to the coroutine, not the kernel")

local bok, berr = coroutine.resume(again)

tap.ok(not bok and tostring(berr):find("already blocked") ~= nil,
    "a second block from the same proc is refused: " .. tostring(berr))

-- ---- sys.call: the send and the wait as one entry ----
--
-- the point of these is that call delivers exactly what send plus recv
-- delivers. it differs only in how many times the proc crosses into the
-- kernel, which is not something a test can see, so what is pinned here
-- is that nothing else changed.

local function call(v)
	return sys.call(w, { value = v, reply = { __right = rp } }, rp)
end

tap.is(call("via call"), "via call", "sys.call round trip")

local ct = call({ a = 1, nested = { b = "two" } })
tap.ok(ct.a == 1 and ct.nested.b == "two", "sys.call carries tables")

-- the reply may be waiting before we ever park -- and must be taken,
-- not slept through. hard to force deliberately; what is checked is
-- that repeated calls in a tight loop all land, since that is the shape
-- that hits both the already-queued and the must-park paths.
local n = 0

for i = 1, 50 do
	if call(i) == i then
		n = n + 1
	end
end
tap.is(n, 50, "50 consecutive calls all delivered in order")

-- a send failure is REPORTED, not raised, exactly as sys.send reports
-- it: nil plus a reason, so the caller keeps its own policy.
local dead = sys.newport()

sys.close(dead)
local dok, derr = pcall(sys.call, dead, "x", rp)

tap.ok(not dok and derr:find("bad right") ~= nil,
    "sys.call on a closed right raises rather than parking forever")

-- an unserializable message raises rather than half-sending
local uok = pcall(sys.call, w, { f = function() end }, rp)

tap.ok(not uok, "sys.call refuses a function like sys.send does")

sys.send(w, { stop = true })
tap.done()
