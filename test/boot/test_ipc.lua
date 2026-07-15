-- serializer round trips, right transfer, refusal of the untransferable

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(9)

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

-- right transfer chain: pass a fresh recv right THROUGH the echo,
-- then use it
local chain = sys.newport()
local got = roundtrip({ carried = { __right = chain } })
tap.ok(type(got.carried) == "table" and got.carried.__right ~= nil,
    "right survived a proc hop")

sys.send(w, { stop = true })
tap.done()
