-- per-proc memory limits: a hog dies alone, kernel and peers survive

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(10)

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

-- a capped proc cannot spawn its way out of the cap. it reports the
-- limit its children actually got: one that asked for more, and one
-- that asked for nothing, which used to mean unlimited.
local cap = 2 * 1024 * 1024
local cpid, wc = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local greedy = sys.spawn("", { mem = 64 * 1024 * 1024 })
	local silent = sys.spawn("")
	local _, _, gl = sys.meminfo(greedy)
	local _, _, sl = sys.meminfo(silent)

	-- both outlive us otherwise, and the parent counts ports the
	-- moment this reply lands
	sys.monitor(greedy)
	sys.monitor(silent)
	local left = 2

	repeat
		local d = thread.recv(sys.SELF)

		if type(d) == "table" and d.exit then
			left = left - 1
		end
	until left == 0

	sys.send(m.reply.__right, { mine = select(3, sys.meminfo()),
	    greedy = gl, silent = sl })
]], { mem = cap })
local rp = sys.newport()

sys.send(wc, { reply = { __right = rp } })
m = thread.recv(rp)

tap.is(m.mine, cap, "a child gets the cap it asked for")
tap.is(m.greedy, cap, "its own child cannot ask for a larger one")
tap.is(m.silent, cap, "and inherits it when it asks for nothing")
sys.close(rp)

-- it and its two children are still exiting; the port count below
-- cannot be read until they have
sys.monitor(cpid)
repeat
	local d = thread.recv(sys.SELF)
until type(d) == "table" and d.exit == cpid

-- no leaks from the carnage
sys.close(wh)
sys.close(wo)
sys.close(wc)
local after = sys.stats()
tap.is(after.ports, base.ports, "ports back to baseline")

tap.done()
