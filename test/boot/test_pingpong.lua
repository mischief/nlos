-- two procs passing messages to each other must not stop the machine.
--
-- a mid-lap wakeup joins the CURRENT runq (see make_ready), so a pair
-- that feeds each other hands the dispatch loop a fresh proc every time
-- it takes one. with an unbounded phase two the lap never ends, and
-- everything at the top of kernel_run's loop -- expire_timers, pump_eth,
-- pump_serial, the idle sleep -- runs only between laps. so a busy pair
-- stops every timer on the machine, in every proc, including procs with
-- no relationship to the pair.
--
-- the timer here is a stand-in for all of that: it is the cheapest
-- observable that depends on a lap ending.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

-- both halves run the same script. the absolute deadline is what stops
-- them: there is no kill, so a proc that ran forever would hold nlive
-- above zero and the machine would never halt.
local BOUNCER = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local peer, deadline = m.peer.__right, m.deadline

	if m.start then
		sys.send(peer, {})
	end
	while sys.uptime_ms() < deadline do
		thread.recv(sys.SELF)
		if sys.uptime_ms() >= deadline then
			break
		end
		sys.send(peer, {})
	end
	-- whichever half stops first leaves the other parked in recv. one
	-- last message wakes it so it can see the deadline for itself.
	sys.send(peer, {})
]]

local apid, ah = sys.spawn(BOUNCER, { name = "ping" })
local bpid, bh = sys.spawn(BOUNCER, { name = "pong" })

tap.ok(apid and bpid, "spawned a pair to bounce a message")

local deadline = sys.uptime_ms() + 2000

sys.send(ah, { peer = { __right = bh }, deadline = deadline, start = true })
sys.send(bh, { peer = { __right = ah }, deadline = deadline })
sys.close(ah)
sys.close(bh)

-- let the exchange get going, so the measurements below are taken with
-- the pair actually feeding each other rather than still starting up.
thread.sleep(50)

local laps0 = sys.stats().laps
local resumes0 = sys.pidstat(apid).resumes

-- the assertion the bug fails: an unrelated proc's timer still fires.
local t0 = sys.uptime_ms()
local t = sys.timer(300)
local fired = thread.recvtimeout(t, 1500)
local waited = sys.uptime_ms() - t0

sys.close(t)

tap.ok(fired == true,
    "a timer fires while two procs pass messages (waited " .. waited .. "ms)")
tap.ok(waited < 1000, "and it is not merely late (" .. waited .. "ms)")

local laps = sys.stats().laps - laps0
local resumes = sys.pidstat(apid).resumes - resumes0

-- without this the test is vacuous: a pair that had already finished, or
-- never started, would pass the timer assertion trivially.
tap.ok(resumes > 100,
    "the pair really was bouncing throughout (" .. resumes .. " resumes)")
-- the direct form of the same property. under the bug this is 0: the lap
-- never ends, so nothing at the top of the loop runs again.
tap.ok(laps > 0, "and the dispatch lap ended repeatedly (" .. laps .. " laps)")

sys.monitor(apid)
sys.monitor(bpid)

local left = 2

while left > 0 do
	local m = thread.recv(sys.SELF)

	if m.exit == apid or m.exit == bpid then
		left = left - 1
	end
end
tap.ok(true, "both halves reached their deadline and exited")

tap.done()
