local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(13)

tap.ok(sys.granted().sched ~= nil, "sched is in the grant table")

-- the boot payload is granted the sched capability
local ok = pcall(sys.set_priority, sys.self(), 4)
tap.ok(ok, "init can set_priority (granted sched)")
tap.is(sys.priority(sys.self()), 4, "weight took effect")

-- clamp
sys.set_priority(sys.self(), 9999)
tap.is(sys.priority(sys.self()), 16, "weight clamps to MAXWEIGHT")
sys.set_priority(sys.self(), 1)

-- an ordinary spawn child has no SCHED right
local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local ok, err = pcall(sys.set_priority, sys.self(), 16)
	sys.send(m.reply.__right, { ok = ok, err = tostring(err) })
]], { name = "victim" })
local rp = sys.newport()
sys.send(h, { reply = { __right = rp } })
local r = thread.recv(rp)
tap.ok(not r.ok, "spawn child denied set_priority")
tap.ok(r.err:find("no scheduling capability") ~= nil,
    "denied with the right error: " .. r.err)

-- ---- scheduling feedback: measure, do not yet dispatch ----
--
-- assertions are on DIRECTION, not magnitude: exact cpu numbers depend
-- on how much else is runnable and on host load, but a spinner must
-- always end up above a blocker and priced lower for it.
local hogpid = sys.spawn([[
	local sys = require("los.sys")
	local t0 = sys.uptime_ms()

	while sys.uptime_ms() - t0 < 2200 do end
]], { name = "hog" })

local idlepid = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.recv(sys.newport())
]], { name = "idler" })

-- long enough for the decay window to fill: cpu is an average over
-- SCHED_DECAY_MS, so a hog measured after 500ms of a 2000ms window reads
-- ~250 per-mille no matter how hard it spins.
thread.sleep(1800)

local hw, hpri, hcpu = sys.priority(hogpid)
local iw, ipri, icpu = sys.priority(idlepid)

tap.ok(hcpu > icpu,
    "a spinning proc accrues cpu over a blocked one (" .. hcpu ..
    " vs " .. icpu .. ")")
tap.ok(hcpu > 500, "and it is most of wall time (" .. hcpu .. ")")
tap.is(icpu, 0, "a proc that never ran accrues none")

-- differentiation only happens under contention: a proc using LESS than
-- an equal share clamps to the top however much it spins, which is plan
-- 9's formula working as intended rather than a missing case.
tap.ok(hpri < ipri,
    "over its share, the spinner is priced below the idler (" .. hpri ..
    " vs " .. ipri .. ")")
tap.is(ipri, iw * 10, "an idle proc clamps to weight * PRI_BASE")
tap.ok(hpri >= 0, "and priority never goes negative (" .. hpri .. ")")

-- cycles have no floor, so even a proc too short-lived to be sampled by
-- any tick-based scheme is still accounted for. an instruction count via
-- the preempt hook was tried and dropped for exactly that reason -- see
-- AGENTS.md.
local shortpid = sys.spawn([[
	local sys = require("los.sys")
	local n = 0

	for i = 1, 100 do
		n = n + i
	end
]], { name = "brief" })

sys.monitor(shortpid)
local sm

repeat
	sm = thread.recv(sys.SELF)
until sm.exit == shortpid

tap.ok(sm.normal, "a brief proc ran and exited normally")

tap.done()
