-- What the serializer refuses, and what a sender cannot make it do.
--
-- The sender picks the shape, the depth and the metatables of what it
-- sends, and the receiver walks all three. These are the limits that
-- hold when it picks them badly.

local sys = require("los.sys")
local buf = require("los.buf")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(15)

local rp = sys.newport("test_bufalias.rp")

-- ---- the same buffer, twice in one message ----

local b = buf.new(64, 0x41)

b:copy(1, "alias")

tap.ok(not pcall(sys.send, rp, { a = { __buf = b }, c = { __buf = b } }),
    "a buffer named twice in one message is refused")
tap.is(#b, 64, "and the sender still holds its bytes")
tap.is(b:sub(1, 5), "alias", "unchanged")

-- the refusal must not have consumed it: it still travels on its own
sys.send(rp, { it = { __buf = b } })

local m = thread.recv(rp)

tap.ok(buf.is(m.it), "the same buffer still travels alone afterwards")
tap.is(m.it:sub(1, 5), "alias", "with its bytes")

-- ---- nested, not just two keys at one level ----

local n = buf.new(32, 0x42)

tap.ok(not pcall(sys.send, rp, { one = { __buf = n },
    deep = { two = { __buf = n } } }),
    "the two mentions may be at different depths")
tap.is(#n, 32, "and that sender keeps its bytes too")

-- ---- two different buffers still travel together ----

local p, q = buf.new(8, 0x43), buf.new(8, 0x44)

sys.send(rp, { p = { __buf = p }, q = { __buf = q } })

local m2 = thread.recv(rp)

tap.ok(buf.is(m2.p) and buf.is(m2.q) and #m2.p == 8 and #m2.q == 8,
    "two distinct buffers in one message still both arrive")

-- ---- depth ----
--
-- Each level of the walk holds a table and a key while it recurses, so
-- a deep message needs more stack than a C function is given. The
-- receiver's walk is the one that matters: the sender chose the depth.

local function nest(d)
	local t = { leaf = "bottom" }

	for i = 1, d do
		t = { down = t, n = i }
	end
	return t
end

sys.send(rp, nest(15))

local deep = thread.recv(rp)
local walk = deep

for _ = 1, 15 do
	walk = walk.down
end

tap.is(walk.leaf, "bottom", "a message nested to the limit arrives whole")
tap.is(deep.n, 15, "with its levels in order")

tap.ok(not pcall(sys.send, rp, nest(64)),
    "past the depth limit it is refused, not walked")

-- ---- metatables ----
--
-- The probes for __right and __buf are raw. A metamethod would run lua
-- in the middle of the walk, and one that raises would leave it holding
-- references it never gave back.

local ran = false
local sneak = setmetatable({}, {
	__index = function(_, k)
		ran = true
		if k == "__right" then
			return 1
		end
		return nil
	end,
})

sys.send(rp, { it = sneak })

local got = thread.recv(rp)

tap.ok(not ran, "__index does not run during the walk")
tap.is(type(got.it), "table", "and the value arrives as the plain table it is")

local boom = setmetatable({}, {
	__index = function() error("from a metamethod") end,
})

tap.ok(pcall(sys.send, rp, { it = boom }),
    "a raising __index cannot interrupt a send")
thread.recv(rp)

-- the port survives it: a walk that longjmped would have pinned it
local after = sys.newport("test_serialize.after")

tap.ok(after ~= nil, "and the machine still hands out ports afterwards")
sys.close(after)
