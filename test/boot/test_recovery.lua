-- erlang-style supervision: a supervisor restarts a crashing worker
-- until it succeeds. exercises error() in procs + monitor-driven
-- recovery.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

-- the worker crashes unless told the magic attempt number. the
-- supervisor (us) respawns it on each DOWN, bumping the attempt.
local worker_code = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	if m.attempt < 3 then
		error("worker failing on attempt " .. m.attempt)
	end
	sys.send(m.report.__right, { ok = true, attempt = m.attempt })
]]

local report = sys.newport("test_recovery.r")
local restarts = 0
local attempt = 0
local result

while true do
	attempt = attempt + 1
	local pid, w = sys.spawn(worker_code)
	sys.monitor(pid)
	sys.send(w, { attempt = attempt, report = { __right = report } })
	sys.close(w)

	local m = thread.recv(sys.SELF)
	if m.normal then
		result = thread.recv(report)
		break
	end
	restarts = restarts + 1
	if restarts > 5 then
		break
	end
end

tap.is(restarts, 2, "supervisor restarted worker twice")
tap.ok(result and result.ok, "worker eventually succeeded")
tap.is(result and result.attempt, 3, "success on third attempt")

-- kernel survived all the crashing: spawn still works
local pid, w = sys.spawn([[ local sys = require("los.sys")
	sys.send(0, "alive") ]])
sys.monitor(pid)
local m = thread.recv(sys.SELF)
tap.is(m.normal, true, "kernel healthy after crash storm")
sys.close(w)

tap.done()
