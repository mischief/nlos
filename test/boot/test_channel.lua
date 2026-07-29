-- threads, channels (rendezvous + buffered), alt, qlock

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(16)

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

-- ---- close ----

-- buffered values survive the close: recv drains before it reports it
local cc = thread.chancreate(2)

cc:send("a")
cc:send("b")
cc:close()
tap.is(cc:recv(), "a", "close does not discard buffered values")
local v, more = cc:recv()

tap.ok(v == "b" and more == true, "second buffered value still reports open")
v, more = cc:recv()
tap.ok(v == nil and more == false, "drained + closed recv is nil, false")

-- idempotent, unlike go's panic-on-double-close
tap.ok(pcall(function() cc:close() end), "close is idempotent")

-- sending after close is a bug and says so
tap.ok(not pcall(function() cc:send("x") end), "send on closed channel raises")

-- a receiver parked BEFORE the close must wake, not hang forever. this
-- is the case the whole feature exists for: a consumer waiting on a
-- producer that finishes.
local pc = thread.chancreate(0)
local woke = nil

thread.spawn(function()
	local x, ok = pc:recv()

	woke = (x == nil and ok == false)
end)
thread.spawn(function()
	sys.yield()		-- let the receiver park first
	pc:close()
end)
thread.run()
tap.ok(woke, "close wakes a receiver already parked")

-- and a sender parked before the close fails rather than hanging
local sc = thread.chancreate(0)
local sfail = nil

thread.spawn(function()
	sfail = not pcall(function() sc:send("never taken") end)
end)
thread.spawn(function()
	sys.yield()
	sc:close()
end)
thread.run()
tap.ok(sfail, "close makes a parked sender raise")

-- alt treats a closed channel as ready, which is what makes it usable
-- for "work, or the producer is done"
local ac = thread.chancreate(0)

ac:close()
local aw, av

thread.spawn(function()
	aw, av = thread.alt({ { c = ac, op = "recv" }, { port = sys.SELF } })
end)
thread.run()
tap.ok(aw == 1 and av == nil, "alt reports a closed channel as ready")

tap.done()
