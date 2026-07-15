-- threads, channels (rendezvous + buffered), alt, qlock

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(8)

-- rendezvous ping/pong
local c = thread.chancreate(0)
local got = {}

thread.spawn(function()
	for _ = 1, 3 do
		got[#got + 1] = c:recv()
	end
end)
thread.spawn(function()
	for i = 1, 3 do
		c:send("ping" .. i)
	end
end)
thread.run()
tap.is(table.concat(got, ","), "ping1,ping2,ping3", "rendezvous channel")

-- buffered channel does not block under capacity
local b = thread.chancreate(2)
local sent = false
thread.spawn(function()
	b:send(1)
	b:send(2)
	sent = true
end)
thread.run()
tap.ok(sent, "buffered sends complete without receiver")
tap.is(b:recv(), 1, "buffered recv order 1")
tap.is(b:recv(), 2, "buffered recv order 2")

-- alt: channel case fires
local d = thread.chancreate(1)
d:send("from-chan")
local which, val
thread.spawn(function()
	which, val = thread.alt({
		{ c = d, op = "recv" },
		{ port = sys.SELF },
	})
end)
thread.run()
tap.is(which, 1, "alt picks ready channel")
tap.is(val, "from-chan", "alt returns channel value")

-- alt: port case fires
sys.send(sys.SELF, "from-port")
thread.spawn(function()
	which, val = thread.alt({
		{ c = thread.chancreate(0), op = "recv" },
		{ port = sys.SELF },
	})
end)
thread.run()
tap.is(val, "from-port", "alt picks ready port")

-- qlock excludes across yields
local l = thread.qlockcreate()
local order = {}
thread.spawn(function()
	l:lock()
	order[#order + 1] = "a-in"
	thread.chancreate(1):nbsend(true)	-- force a scheduling point
	sys.yield()
	order[#order + 1] = "a-out"
	l:unlock()
end)
thread.spawn(function()
	l:lock()
	order[#order + 1] = "b"
	l:unlock()
end)
thread.run()
tap.is(table.concat(order, ","), "a-in,a-out,b", "qlock holds across yield")

tap.done()
