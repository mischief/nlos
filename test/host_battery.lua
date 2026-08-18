#!/usr/bin/env lua5.4
-- the battery curve in lib/ps.lua.
--
-- The kernel reports millivolts and nothing else, so the whole of the
-- policy -- what counts as empty, and how a flat middle is spread over
-- the range -- is this one function, and it is testable off the board.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local mv = nil		-- what the fake kernel reports

package.loaded["los.sys"] = {
	MAXMSG = 8192,
	battery = function()
		return mv
	end,
	stats = function()
		return { procs = 3, ports = 9, heap_used = 4096 }
	end,
	procs = function() return {} end,
	ports = function() return {} end,
}

local ps = require("ps")

local n = 0
local fails = 0

local function ok(cond, name)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, name))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, name))
	end
end

-- no pack: nothing, not zero. A machine on wall power must be tellable
-- from one that is flat.
mv = nil
local v, pct = ps.battery()
ok(v == nil and pct == nil, "no battery reports nothing")

mv = 4200
v, pct = ps.battery()
ok(v == 4200 and pct == 100, "a full cell is 100%")

mv = 4500
v, pct = ps.battery()
ok(pct == 100, "above full clamps to 100%")

mv = 3000
v, pct = ps.battery()
ok(pct == 0, "the cutoff is 0%")

mv = 2000
v, pct = ps.battery()
ok(v == 2000 and pct == 0, "below the cutoff clamps to 0%")

-- the middle: the point of the curve is that it is not linear in volts.
-- 3.7V is under half by voltage and 40% by charge.
mv = 3700
v, pct = ps.battery()
ok(pct == 40, "3.7V is 40%")

mv = 3750
v, pct = ps.battery()
ok(pct == 50, "3.75V interpolates to 50%")

-- monotone across the whole range, which a hand-written table is one
-- transposed pair away from not being.
local last = -1
local mono = true

for x = 2800, 4300, 10 do
	mv = x
	local _, p = ps.battery()

	if p < last then
		mono = false
	end
	last = p
end
ok(mono, "percent never falls as voltage rises")

-- the stats line carries it, and says nothing where there is no pack.
mv = nil
ok(not tostring(ps.stats):find("bat="), "no bat= without a battery")

mv = 3800
ok(tostring(ps.stats):find("bat=60%% 3%.80V") ~= nil,
    "the stats line reports the battery")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
