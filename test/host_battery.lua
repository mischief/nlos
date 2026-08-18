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

-- the curve, through of(): a true voltage in, what it means out. The
-- pin's own correction is read()'s business and is checked below.
local battery = require("battery")

local v, pct, chg = battery.of(nil)

ok(v == nil and pct == nil, "no battery reports nothing")

v, pct = battery.of(4200)
ok(v == 4200 and pct == 100, "a full cell is 100%")

v, pct, chg = battery.of(4030)
ok(chg == false and pct > 80 and pct < 100,
    "a charged pack alone is not charging")

v, pct = battery.of(3000)
ok(pct == 0, "the cutoff is 0%")

v, pct = battery.of(2000)
ok(v == 2000 and pct == 0, "below the cutoff clamps to 0%")

-- the middle: the point of the curve is that it is not linear in volts.
-- 3.7V is under half by voltage and 40% by charge.
v, pct = battery.of(3700)
ok(pct == 40, "3.7V is 40%")

v, pct = battery.of(3750)
ok(pct == 50, "3.75V interpolates to 50%")

-- monotone across the whole range, which a hand-written table is one
-- transposed pair away from not being.
local last = -1
local mono = true

for x = 2800, 4300, 10 do
	local _, p = battery.of(x)

	if p < last then
		mono = false
	end
	last = p
end
ok(mono, "percent never falls as voltage rises")

-- the pin reads low, so read() lifts what it is given. Metered on a
-- T-Deck: 3.750V at the pack against 3.500V reported.
mv = 3500
ok(battery.read() == 3750, "read() corrects the pin against the meter")

mv = nil
ok(battery.read() == nil, "and still reports nothing where no pack is")

-- the charger's node, well above what a corrected cell can reach
mv = 4666
local _, cpct, cchg = battery.read()

ok(cchg == true and cpct == 100, "the charger's node reads as charging")

-- the stats line carries it, and says nothing where there is no pack.
mv = nil
ok(not tostring(ps.stats):find("bat="), "no bat= without a battery")

-- 3.547V at the pin is 3.80V corrected, which the curve calls 60%
mv = 3547

local line = tostring(ps.stats)

ok(line:find("bat=60%% 3%.80V") ~= nil,
    "the stats line reports the battery")
ok(not line:find("chg"), "and says nothing of a charger that is absent")

mv = 4666
ok(tostring(ps.stats):find("chg") ~= nil,
    "the stats line says when it is charging")

-- the plug-in transient, through the meter: a caller that polls carries
-- the history, and read() itself keeps none.
local meter = battery.meter()

mv = 3500
ok(meter() == 3750, "the meter's first reading is the pack's")

mv = 3080
ok(meter() == 3750, "a sudden collapse is not published")

mv = 3500
ok(meter() == 3750, "and the pack's own reading comes straight back")

-- the same guard must not freeze a real move: unplugging is a genuine
-- jump, and the reading after it is what confirms one.
mv = 4300
ok(meter() == 3750, "a real jump waits for a second opinion")
ok(meter() == 4607, "which the next reading gives")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
