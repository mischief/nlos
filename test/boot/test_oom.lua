-- who is given up when memory runs out.
--
-- Not whoever allocated next. A shortage is noticed in the allocator
-- and answered at the top of a lap, where killing is safe: the cached
-- chunks go back first, and a shortage that survives that takes the
-- largest proc marked expendable at spawn.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(5)

local rp = sys.newport("test_oom.r")

-- expendability is inherited and cannot be refused: a child of an
-- expendable proc goes with it.
local cpid, ch = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local kid = sys.spawn("require('los.thread').recv(require('los.sys').SELF)",
	    { expendable = false })

	sys.send(m.reply.__right, { kid = kid })
	thread.recv(sys.SELF)
]], { expendable = true })

sys.send(ch, { reply = { __right = rp } })
tap.ok(thread.recv(rp) ~= nil, "an expendable proc spawns a child")

-- ---- the hog ----
--
-- No cap, so only the pool bounds it, and expendable, so it is what
-- the kernel should choose. Watched before it starts: the lap can
-- reach it the moment it stops, and a later monitor answers noproc.
-- pcall catches its own allocation failure, so it survives holding
-- what it took and stops asking for more. Nothing else allocates
-- after that, so what kills it can only be the lap.
local hog, hh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local t = {}

	pcall(function()
		for i = 1, 1e9 do
			t[i] = ("x"):rep(4096)
		end
	end)
	thread.recv(sys.SELF)
]], { expendable = true })

sys.monitor(hog)

local died = thread.recv(sys.SELF)

tap.is(died.exit, hog, "the hog is what died")
tap.is(died.normal, false, "and it died abnormally")
tap.ok(died.reason and died.reason:find("memory") ~= nil,
    "of memory: " .. tostring(died.reason))

-- the machine is still there afterwards, which is the point: a
-- shortage costs an app rather than the kernel.
-- it answers rather than being watched: a proc this small can finish
-- before a monitor lands, and a monitor that arrives after the proc has
-- gone is answered with noproc, which reads as an abnormal death.
local after, wa = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)

	sys.send(m.reply.__right, { alive = true })
]])

sys.send(wa, { reply = { __right = rp } })
tap.ok(thread.recv(rp) ~= nil, "and the machine still spawns")

sys.close(ch)
sys.close(hh)
sys.close(wa)
sys.close(rp)
tap.done()
