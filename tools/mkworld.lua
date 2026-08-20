-- rasterise continent outlines into a land bitmask, as hex.
--
-- Run on the host; the string goes into bin/gpsui.lua. The board must
-- not pay for point-in-polygon: it samples one bit per pixel instead.

local NX, NY = 192, 96		-- 1.875 degrees a cell

local POLY = {
	-- north america
	{ -168, 66, -160, 71, -140, 70, -125, 70, -110, 68, -95, 72,
	  -85, 70, -80, 73, -70, 68, -60, 55, -55, 52, -65, 45, -70, 42,
	  -75, 35, -81, 25, -83, 23, -90, 21, -95, 18, -88, 15, -83, 9,
	  -78, 8, -82, 15, -92, 15, -97, 16, -105, 20, -110, 24, -115, 30,
	  -124, 35, -125, 48, -135, 57, -150, 59, -165, 55 },
	-- greenland
	{ -45, 60, -20, 70, -20, 82, -35, 84, -58, 82, -55, 70 },
	-- south america
	{ -81, 10, -76, 8, -60, 10, -52, 5, -35, -5, -38, -15, -48, -25,
	  -58, -35, -62, -40, -65, -45, -68, -52, -75, -52, -73, -45,
	  -71, -35, -70, -20, -75, -15, -81, -5 },
	-- africa
	{ -17, 15, -16, 20, -10, 30, 0, 36, 10, 37, 20, 32, 32, 31,
	  35, 25, 43, 12, 51, 12, 48, 0, 40, -15, 35, -25, 25, -34,
	  18, -35, 12, -18, 8, 4, 0, 5, -8, 5, -13, 10 },
	-- eurasia
	{ 0, 36, 10, 37, 20, 40, 30, 37, 35, 37, 45, 40, 50, 45, 60, 42,
	  70, 38, 78, 30, 88, 22, 95, 20, 100, 14, 105, 10, 108, 20,
	  117, 23, 122, 30, 122, 40, 130, 43, 135, 50, 142, 54, 145, 60,
	  160, 62, 170, 66, 179, 68, 179, 72, 140, 76, 100, 78, 70, 73,
	  60, 70, 40, 68, 30, 70, 25, 71, 10, 63, 5, 60, -5, 58,
	  -10, 44, -9, 38 },
	-- australia
	{ 113, -22, 114, -32, 118, -35, 129, -32, 138, -35, 145, -38,
	  150, -37, 153, -28, 146, -19, 142, -11, 132, -11, 125, -14 },
	-- new guinea and the archipelago
	{ 95, 5, 120, 0, 140, -2, 150, -9, 140, -8, 120, -8, 100, -3 },
	-- madagascar
	{ 43, -12, 50, -15, 48, -25, 44, -20 },
	-- japan
	{ 130, 31, 141, 36, 146, 44, 140, 42, 132, 34 },
	-- the british isles
	{ -6, 50, 2, 52, 0, 58, -6, 58 },
	-- new zealand
	{ 166, -46, 175, -41, 178, -37, 172, -40 },
}

-- Cut back out of the land above. A coastline is what makes a
-- continent recognisable, and the bites out of one -- Hudson Bay, the
-- Gulf, the Mediterranean -- do more of that at this size than the
-- outer edge does.
local SUB = {
	-- hudson bay
	{ -95, 51, -78, 51, -78, 63, -95, 64 },
	-- the gulf of mexico
	{ -97, 19, -81, 19, -81, 29, -89, 30, -97, 27 },
	-- the mediterranean, and the black sea after it
	{ -5, 36, 12, 33, 34, 31, 36, 36, 12, 45, 3, 43 },
	{ 28, 41, 41, 41, 41, 47, 28, 47 },
	-- the caspian
	{ 47, 37, 54, 37, 54, 47, 47, 47 },
	-- the baltic and the north sea
	{ 10, 54, 25, 54, 30, 66, 17, 66 },
	{ -2, 51, 8, 51, 8, 60, -2, 60 },
	-- the red sea and the gulf
	{ 33, 13, 43, 13, 43, 30, 33, 30 },
	{ 48, 24, 57, 24, 57, 30, 48, 30 },
	-- hudson strait through to the labrador sea
	{ -70, 55, -55, 55, -55, 62, -70, 62 },
	-- the bay of bengal
	{ 80, 6, 95, 6, 95, 21, 80, 21 },
	-- and the gulf of california
	{ -115, 23, -108, 23, -108, 31, -115, 31 },
}

local function inside(poly, x, y)
	local n = #poly // 2
	local hit = false
	local j = n

	for i = 1, n do
		local xi, yi = poly[i * 2 - 1], poly[i * 2]
		local xj, yj = poly[j * 2 - 1], poly[j * 2]

		if (yi > y) ~= (yj > y) and
		    x < (xj - xi) * (y - yi) / (yj - yi) + xi then
			hit = not hit
		end
		j = i
	end
	return hit
end

local bits = {}

for row = 0, NY - 1 do
	-- cell centre, +90 at the top
	local lat = 90 - (row + 0.5) * (180 / NY)

	for col = 0, NX - 1 do
		local lon = -180 + (col + 0.5) * (360 / NX)
		local land = lat < -68	-- antarctica, as a cap

		if not land then
			for _, p in ipairs(POLY) do
				if inside(p, lon, lat) then
					land = true
					break
				end
			end
		end
		if land and lat > -60 then
			for _, p in ipairs(SUB) do
				if inside(p, lon, lat) then
					land = false
					break
				end
			end
		end
		bits[#bits + 1] = land and 1 or 0
	end
end

local out = {}

for i = 1, #bits, 8 do
	local b = 0

	for k = 0, 7 do
		b = b | ((bits[i + k] or 0) << (7 - k))
	end
	out[#out + 1] = ("%02x"):format(b)
end

local hex = table.concat(out)

io.write(("-- %dx%d, %d bytes\n"):format(NX, NY, #hex // 2))
for i = 1, #hex, 64 do
	io.write(('    "%s" ..\n'):format(hex:sub(i, i + 63)))
end

-- a look at what it will be, so the shapes can be judged before the
-- board ever draws them
io.write("\n")
for row = 0, NY - 1 do
	local line = {}

	for col = 0, NX - 1 do
		line[#line + 1] = bits[row * NX + col + 1] == 1 and "#" or "."
	end
	io.write(table.concat(line), "\n")
end
