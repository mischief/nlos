local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(18)

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
local rp = sys.newport("test_sched.rp")
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

	thread.recv(sys.newport("test_sched"))
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
-- "never ran" is loose: a proc runs one slice to reach the recv it blocks
-- in, and that startup shows in the 500ms decay window before decaying
-- away -- single digits, and load-dependent (0 idle, 3 under a busy
-- parallel suite), so a fixed threshold is the wrong shape. What holds
-- regardless is that it stays a tiny fraction of a spinner pegged near
-- 1000; asserting literally 0 was codifying a fast host's rounding.
tap.ok(icpu * 10 < hcpu,
    "a blocked proc accrues far less than a spinner (" .. icpu ..
    " vs " .. hcpu .. ")")

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

-- ---- sys.pidstat: one proc's row, and the resume count in it ----
--
-- resumes is the count next to the rate. cputime says how much of the
-- machine a proc took, this says in how many pieces -- and a proc
-- round-tripping on ipc has a small share spread over a large count,
-- which is the shape neither number shows on its own.
local st = sys.pidstat(sys.self())

tap.ok(st.pid == sys.self() and st.name == sys.name() and
    st.wchan == sys.wchan(),
    "pidstat agrees with the accessors it replaces in ps")

tap.ok(st.resumes > 0, "this proc has been resumed at least once")

-- park, so the kernel has to pick us up again rather than us never
-- having left. Sleeping is what guarantees a resume: a busy loop can be
-- preempted, but nothing makes it certain within the test.
thread.sleep(20)

local r1 = sys.pidstat(sys.self()).resumes

tap.ok(r1 > st.resumes,
    string.format("and the count advances across a park (%d -> %d)",
    st.resumes, r1))

-- monotonic: it is a total, not a rate, so it can never fall
thread.sleep(5)
tap.ok(sys.pidstat(sys.self()).resumes >= r1,
    "the count never goes backwards")

tap.ok(not pcall(sys.pidstat, 99999), "pidstat on a dead pid is an error")

tap.done()
