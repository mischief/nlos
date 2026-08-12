-- Stopping a proc, and what "stopped" has to mean.
--
-- The claim under test is not that a flag was set. It is that no
-- instruction of the target runs while it is stopped, which is what
-- makes reading its frames worth anything -- so the measure is
-- sys.pidstat().cputime, taken across a sleep, and it has to be zero.
--
-- Two targets, because they stop by different routes. A spinner is
-- running, so the hook is what cuts it; a parked proc runs no hook at
-- all and is woken into the stop by make_ready instead.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(13)

local notice = sys.newport("test_dbgstop.notice")

-- ---- a proc that never yields on its own ----
local spin, spinh = sys.spawn([[
	local n = 0
	while true do n = n + 1 end
]], { name = "dbgspin" })

tap.ok(dbg.attach(spin, notice), "attach to the spinner")
tap.ok(dbg.stop(spin), "stop it")

-- the stop is committed at the kernel boundary, which the spinner
-- reaches within a quantum because the count hook cuts it.
local stopped
for _ = 1, 200 do
	if sys.wchan(spin) == "stopped" then stopped = true break end
	thread.sleep(10)
end

tap.ok(stopped, "it reports stopped")
tap.ok(dbg.status(spin).stopped, "and dbg.status agrees")

local m = thread.recvtimeout(notice, 2000)

tap.ok(m ~= nil and m.dbg == spin, "the debugger was told")
tap.ok(m and m.stop == "request", "with the reason: " ..
    tostring(m and m.stop))

-- the measurement that matters
local before = sys.pidstat(spin).cputime

thread.sleep(200)

local after = sys.pidstat(spin).cputime

tap.ok(after == before,
    ("no cpu burned while stopped (%d cycles over 200ms)"):format(
    after - before))

tap.ok(dbg.cont(spin), "continue it")

before = sys.pidstat(spin).cputime
thread.sleep(200)
after = sys.pidstat(spin).cputime
tap.ok(after > before, "and it runs again (" .. (after - before) ..
    " cycles)")

-- ---- a proc parked on a port ----
local park, parkh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...
	local m = thread.recv(sys.SELF)

	sys.send(a.reply.__right, { woke = true })
]], { name = "dbgpark",
      arg = { reply = { __right = sys.sendright(notice) } } })

thread.sleep(50)
tap.ok(dbg.attach(park, notice), "attach to the parked proc")
tap.ok(dbg.stop(park), "ask it to stop")

-- it is blocked, so the request is honoured immediately: there is
-- nothing of it running to interrupt.
tap.ok(sys.wchan(park) == "stopped",
    "a blocked proc stops where it stands (" .. sys.wchan(park) .. ")")

-- the message it was waiting for must not be lost: it is queued, its
-- waiter stays linked, and continuing delivers it.
sys.send(parkh, { go = true })
thread.sleep(50)
dbg.cont(park)

local woke
for _ = 1, 100 do
	local r = thread.recvtimeout(notice, 50)

	if r and r.woke then woke = true break end
end
tap.ok(woke, "the wake it slept through was still there on continue")

sys.close(spinh)
sys.close(parkh)
sys.close(notice)
tap.done()
