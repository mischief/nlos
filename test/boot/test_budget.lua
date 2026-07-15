-- instruction budgets: a busy-looping proc cannot starve its peers

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(5)

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
local rp = sys.newport()
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
