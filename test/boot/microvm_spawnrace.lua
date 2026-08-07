-- sys.spawn's arg, delivered while another cpu is looking for work.
--
-- api_spawn pushes the arg onto the child's stack after proc_new has
-- built it. A child that were runnable at creation could be dispatched
-- in that window and reach its first line with no `...`, so proc_new
-- leaves it hatching and proc_launch runs it once the arg is there.
--
-- The window is a few instructions wide, so one spawn finds it rarely
-- and forty find it often.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

local N = 40
local rp = sys.newport()
local myright = sys.sendright(rp)

local child = [[
	local a = ...
	local sys = require("los.sys")

	-- a child that got no arg has no way to report it: the reply
	-- right was in the arg. It sends nothing, and the count below is
	-- what notices.
	if type(a) == "table" and a.reply then
		sys.send(a.reply.__right, { n = a.n })
	end
]]

-- one at a time, waiting for each. Losing the race needs another cpu
-- already idle at that instant, and a burst of spawns keeps the other
-- cpus busy with the earlier children -- the one shape that does not
-- test this.
local spawned = 0
local seen = {}
local got = 0

for i = 1, N do
	local pid = sys.spawn(child,
	    { arg = { n = i, reply = { __right = myright } } })

	if pid then
		spawned = spawned + 1
	end

	local m = thread.recvtimeout(rp, 2000)

	if type(m) == "table" and m.n then
		seen[m.n] = (seen[m.n] or 0) + 1
		got = got + 1
	end
end

tap.is(spawned, N, N .. " children spawned")
tap.is(got, N, "every child reported")

local missing = {}

for i = 1, N do
	if seen[i] ~= 1 then
		missing[#missing + 1] = i
	end
end

tap.ok(#missing == 0,
    "every child got its own arg" ..
    (#missing > 0 and (" (missing " .. table.concat(missing, ",") .. ")") or ""))

tap.done()
