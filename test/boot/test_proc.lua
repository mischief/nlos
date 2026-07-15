-- proc lifecycle: monitors, exit reasons, dead ports, refcounts

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(10)

local base = sys.stats()

-- crash: abnormal exit with reason
local pid1, w1 = sys.spawn([[ error("doom") ]])
sys.monitor(pid1)
local m = thread.recv(sys.SELF)
tap.is(m.exit, pid1, "crash notification carries pid")
tap.is(m.normal, false, "crash is not normal")
tap.ok(m.reason and m.reason:find("doom") ~= nil, "crash reason delivered")

-- normal exit
local pid2, w2 = sys.spawn([[ local x = 1 + 1 ]])
sys.monitor(pid2)
m = thread.recv(sys.SELF)
tap.is(m.exit, pid2, "normal exit notification")
tap.is(m.normal, true, "normal exit flagged normal")

-- monitoring the dead: instant noproc
sys.monitor(pid1)
m = thread.recv(sys.SELF)
tap.is(m.reason, "noproc", "monitor of dead pid returns noproc")

-- dead port send returns false
local ok = sys.send(w1, "hello ghost")
tap.is(ok, false, "send to dead proc port returns false")

-- child garbage collected: ports return to baseline once our
-- spawn rights are closed
local pid3, w3 = sys.spawn([[
	local sys = require("los.sys")
	sys.newport()
	sys.newport()
	sys.send(0, "queued to self, never received")
	error("die messy")
]])
sys.monitor(pid3)
m = thread.recv(sys.SELF)
tap.is(m.normal, false, "messy child died abnormally")

sys.close(w1)
sys.close(w2)
sys.close(w3)
local after = sys.stats()
tap.is(after.ports, base.ports, "ports back to baseline (no leaks)")
tap.is(after.procs, base.procs, "procs back to baseline")

tap.done()
