-- instruction budgets: a busy-looping proc cannot starve its peers
--
-- The budget is also inherited: a child may ask for a smaller one than
-- its parent holds and not a larger one, so no proc can spawn its way
-- out of the containment it was given. Same rule as opts.mem, which
-- test_memlimit covers from the other side.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(8)

-- unleash a hostile spinner
local spid = sys.spawn([[ while true do end ]])
tap.ok(spid ~= nil, "spinner spawned")

-- we still get scheduled: round trip an echo child while it spins
local _, w = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	sys.send(m.reply.__right, "still alive")
]])
local rp = sys.newport("test_budget.rp")
sys.send(w, { reply = { __right = rp } })
local m = thread.recv(rp)
tap.is(m, "still alive", "echo responsive while spinner runs")

-- and we can keep getting slices repeatedly
local slices = 0
for _ = 1, 10 do
	sys.yield()
	slices = slices + 1
end
tap.is(slices, 10, "parent scheduled 10 times under load")

-- custom reductions option accepted and proc functions
local _, w2 = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	sys.send(m.reply.__right, "tiny budget ok")
]], { reductions = 1000 })
sys.send(w2, { reply = { __right = rp } })
m = thread.recv(rp)
tap.is(m, "tiny budget ok", "spawn with custom reductions works")

-- a child on a small budget cannot spawn its way back to a large one.
-- it reports what its grandchild actually got, and what it holds itself.
local _, w3 = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local mine = sys.pidstat().reductions
	-- ask for far more than we hold, and for nothing at all
	local greedy = sys.spawn("", { reductions = 1000000 })
	local silent = sys.spawn("")

	sys.send(m.reply.__right, {
		mine = mine,
		greedy = sys.pidstat(greedy).reductions,
		silent = sys.pidstat(silent).reductions,
	})
]], { reductions = 500 })
sys.send(w3, { reply = { __right = rp } })
m = thread.recv(rp)

tap.is(m.mine, 500, "a child gets the budget it asked for")
tap.is(m.greedy, 500, "its own child cannot ask for a larger one")
tap.is(m.silent, 500, "and inherits it when it asks for nothing")

-- in-state threads preempt too: two spinning threads interleave
local a, b = 0, 0
local co_a = thread.spawn(function()
	for _ = 1, 1e6 do a = a + 1 end
end)
local co_b = thread.spawn(function()
	for _ = 1, 1e6 do b = b + 1 end
end)
-- run a bounded number of scheduler rounds by hand
local rounds = 0
while (coroutine.status(co_a) ~= "dead" or
    coroutine.status(co_b) ~= "dead") and rounds < 1000 do
	thread.run()
	rounds = rounds + 1
end
tap.ok(a == 1e6 and b == 1e6, "both busy threads completed via preemption")

tap.done()
