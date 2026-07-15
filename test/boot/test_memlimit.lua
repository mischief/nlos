-- per-proc memory limits: a hog dies alone, kernel and peers survive

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

local base = sys.stats()

-- meminfo sane for self (unlimited init proc)
local used, peak, limit = sys.meminfo()
tap.ok(used > 0, "self mem_used positive")
tap.ok(peak >= used, "self peak >= used")
tap.is(limit, 0, "init proc unlimited")

-- hog: allocates way past its cap, must die of ERRMEM
local hog, wh = sys.spawn([[
	local t = {}
	for i = 1, 1e9 do
		t[i] = ("x"):rep(1000)
	end
]], { mem = 2 * 1024 * 1024 })
sys.monitor(hog)
local m = thread.recv(sys.SELF)
tap.is(m.normal, false, "hog died abnormally")
tap.ok(m.reason and m.reason:find("memory") ~= nil,
    "reason mentions memory: " .. tostring(m.reason))

-- a well-behaved proc under the same limit is fine
local ok_pid, wo = sys.spawn([[
	local sys = require("los.sys")
	local t = {}
	for i = 1, 100 do t[i] = i end
	sys.send(0, "fits")
]], { mem = 2 * 1024 * 1024 })
sys.monitor(ok_pid)
m = thread.recv(sys.SELF)
tap.is(m.normal, true, "modest proc under same limit survives")

-- no leaks from the carnage
sys.close(wh)
sys.close(wo)
local after = sys.stats()
tap.is(after.ports, base.ports, "ports back to baseline")

tap.done()
