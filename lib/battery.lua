-- battery: millivolts from the kernel, as a figure a person reads.
--
-- What counts as empty is a curve over a chemistry, so it lives here
-- and not in the kernel: pushing a file corrects it. Its own module so
-- a panel can have the number without the rest of lib/ps.lua.

local sys = require("los.sys")

local M = {}

-- a single cell's resting voltage against its charge, in millivolts.
-- Li-ion is flat across the middle and steep at both ends, so a linear
-- reading of volts would sit at "half full" for most of a discharge.
-- Interpolated between the points, clamped outside them.
local CURVE = {
	{ 3000, 0 }, { 3300, 10 }, { 3600, 25 }, { 3700, 40 },
	{ 3800, 60 }, { 3950, 80 }, { 4100, 95 }, { 4200, 100 },
}

-- above a cell's own maximum, something external is holding the pin up:
-- the charger, which on the T-Deck sits across the same divider. So a
-- reading over the top of the curve is how charging is detected, there
-- being no status pin to ask. Measured: 4.03V on the pack alone against
-- 4.64V on USB.
local CHARGING = 4250

-- read() -> millivolts, percent, charging. Nothing where there is no
-- pack, which is every machine that runs on wall power.
function M.read()
	local mv = sys.battery and sys.battery()

	if not mv then
		return nil
	end
	if mv >= CHARGING then
		return mv, 100, true
	end
	if mv <= CURVE[1][1] then
		return mv, 0, false
	end
	for i = 2, #CURVE do
		local lo, hi = CURVE[i - 1], CURVE[i]

		if mv <= hi[1] then
			local f = (mv - lo[1]) / (hi[1] - lo[1])

			return mv, math.floor(lo[2] + f * (hi[2] - lo[2]) + 0.5),
			    false
		end
	end
	return mv, 100, false
end

return M
