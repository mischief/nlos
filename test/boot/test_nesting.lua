-- the quantum has to reach code at any coroutine depth.
--
-- preempt_hook decides on a per-proc wall-clock quantum, but lua_yield
-- unwinds only to the resumer of the state it fired in. one level down
-- that is thread.run, two levels down it is whatever scheduler that
-- thread is running -- and none of those is the kernel, so the yield
-- suspends a coroutine while the proc keeps the cpu.
--
-- the kernel closes that by arming states to trip on their next
-- instruction: p->co first, and if that trip does not land, every
-- coroutine of the proc, which it can do because src/coreg.h keeps an
-- exact list rather than inferring one.
--
-- this measures share of throughput rather than latency, because that
-- is where the failure shows. a proc that escapes the quantum does not
-- stall anyone for a long stretch; it steals a little on every slice,
-- so the max gap stays near a millisecond while everyone else's
-- throughput collapses. an unfixed depth-2 spinner leaves the rest of
-- the machine 0.01 of its idle rate.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(4)

local function work(ms)
	local t0 = sys.uptime_ms()
	local n = 0

	while sys.uptime_ms() - t0 < ms do n = n + 1 end
	return n
end

local base = work(250)

tap.ok(base > 0, "measured an idle baseline (" .. base .. ")")

-- a spinner two schedulers down: thread.run resumes a thread, that
-- thread resumes a coroutine of its own, and the coroutine spins.
local _, h = sys.spawn([[
	local thread = require("los.thread")

	thread.spawn(function()
		local c = coroutine.create(function()
			local i = 0
			while true do i = i + 1 end
		end)

		while true do
			coroutine.resume(c)
		end
	end)
	thread.run()
]], { name = "nestspin" })

thread.sleep(50)
local share = work(250) / base

tap.diag(("nested spinner: %.2fx of idle throughput"):format(share))

-- fair is ~0.5 with one competitor. the threshold is loose on purpose:
-- the failure is not a near miss, it is two orders of magnitude.
tap.ok(share > 0.25,
    ("the quantum reaches a spinner two levels down (%.2fx)"):format(share))
sys.close(h)

-- and the list has to survive coroutines coming and going. every one
-- is unlinked in kernel_cofree, which the collector reaches through
-- ordinary collection and through lua_close alike, so a proc that
-- churns coroutines past the collector and then exits exercises both.
local rep = sys.newport()
local _, h3 = sys.spawn([[
	local a = ...
	local sys = require("los.sys")

	for _ = 1, 300 do
		local co = coroutine.create(function() coroutine.yield() end)

		coroutine.resume(co)
		if _ % 50 == 0 then collectgarbage("collect") end
	end
	collectgarbage("collect")
	sys.send(a.rep.__right, "survived")
]], { name = "churn2", arg = { rep = { __right = rep } } })

tap.is(thread.recvtimeout(rep, 10000), "survived",
    "a proc that churns coroutines through the collector stays up")
sys.close(h3)

-- and the machine is still healthy afterwards
tap.ok(work(100) > 0, "the machine still runs after the churn")

sys.close(rep)
tap.done()
