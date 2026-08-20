-- gpsui: where the machine is, on the panel. q or the tray leaves,
-- and the scroll wheel or the ball turns the earth.
--
-- Satellites are placed where they are, not where a dial would put
-- them: a bearing and an elevation from the receiver, a range from the
-- orbit, and the whole scene projected. See lib/geometry.lua.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")
local memdraw = require("memdraw")
local geom = require("geometry")
local mouse = require("mouse")

local fb = prog.screen()

if not fb then
	io.stderr:write("gpsui: no framebuffer on this machine\n")
	os.exit(1)
end

local gps = prog.gps()

if not gps then
	io.stderr:write("gpsui: no receiver on this machine\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local OK, WARM = 0x60c060, 0xc0a020

local FW, FH = 6, 12
local ROWH = FH + 4

-- ---- text ----

-- Padded to the width it is given, so a line erases what it replaces.
-- The window is cleared once: a full repaint at 1Hz is what makes a
-- panel flicker, since every rectangle is a message and the whole
-- window would go out to move one digit.
local function text(x, y, s, fg, bg, pad)
	s = tostring(s or "")
	if pad and #s < pad then
		s = s .. string.rep(" ", pad - #s)
	end
	if s == "" then
		return
	end

	local room = (W - x) // FW

	if #s > room then
		s = s:sub(1, room)
	end

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

local COLS = (W - 4) // FW
local ROW = {}

for i = 0, 5 do
	ROW[i] = 2 + i * ROWH
end

-- ---- the earth ----

local PLOTY = ROW[5] + ROWH + 2
local S = math.min(H - PLOTY - FH - 8, W - 4)
local CX, CY = S // 2, S // 2
local RPX = S // 2 - 12		-- the earth, in pixels

local SEA, LAND = 0x14498a, 0x2f7a44
local SEADK, LANDDK = 0x081f3c, 0x123018
local LIMB, GRID = 0x6fa8ff, 0x1a2a44
local HERE = 0xffd020
local SAT, SATW, SATOK, BEHIND = 0xd03030, 0xd0a020, 0x40d060, 0x304050

-- 96 by 48 cells of land or sea, rasterised from continent outlines by
-- tools/mkworld.lua. Sampling one bit is what the board can afford per
-- pixel; testing a polygon is not.
local NX, NY = 96, 48
local WORLDHEX =
	"000000000000000000000000000000000000000000000000000000007fe0" ..
	"000000000000000000007fe00000007f8000000000007fe000001ffffff8" ..
	"07ff0ff87fc00383ffffffff1ffffffc3f000ffffffffff81ffffffe1800" ..
	"3fffffffffc00e3ffffe0001fffffffffc000007ffff0003fffffffffc00" ..
	"0003ffff8003fffffffff0000001fffe0003ffffffffe0000001fffc0007" ..
	"fff9ffffe2000001fff80003fbe03fff84000001fff00000e0001fff8800" ..
	"0000ffe00003fc000fff800000003fe00007ff8007ff000000001fc0000f" ..
	"ff8001fe000000000f00000fffc00078000000000200000fffe000380000" ..
	"00000040000fffe000100000000000210007fff8000000000000003fc003" ..
	"fff8000000000000003ff0003ff8003800000000003ff8003ff8003ff800" ..
	"0000003ffe001ff00007fe000000001ffc001fe0000000000000000ffc00" ..
	"1fe000003c000000000ff8001fc80000fe0000000007f0001fc80001fe00" ..
	"00000007e0000f800003ff0000000007c0000f000003ff80000000078000" ..
	"06000003ff00000000070000000000000700000000070000000000000002" ..
	"0000000600000000000000040000000c0000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"00000000000000000000000000000000ffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

local WORLD = (WORLDHEX:gsub("%x%x", function(h)
	return string.char(tonumber(h, 16))
end))

-- z is a sine of latitude, so the row is an asin away -- but this chip
-- has no double precision in hardware and every one costs, so the
-- answer is a table of 512 buckets built once.
local NZ = 512
local ROWOF = {}

for i = 0, NZ do
	local z = i * 2 / NZ - 1
	local row = math.floor((math.pi / 2 -
	    math.asin(z < -1 and -1 or (z > 1 and 1 or z))) * NY / math.pi)

	ROWOF[i] = (row < 0 and 0) or (row >= NY and NY - 1) or row
end

local ZSCALE = NZ / 2
local COLSCALE = NX / (2 * math.pi)

local function landat(z, lon)
	local row = ROWOF[math.floor((z + 1) * ZSCALE)] or 0
	local col = math.floor((lon + math.pi) * COLSCALE)

	if col < 0 then
		col = 0
	elseif col >= NX then
		col = NX - 1
	end

	local bit = row * NX + col
	local b = WORLD:byte(bit // 8 + 1) or 0

	return (b >> (7 - bit % 8)) & 1 == 1
end

-- ---- the view ----
--
-- East, north and up at the receiver, which puts the observer in the
-- middle and the sky where it is. Scrolling turns that frame, so the
-- same scene swings out to the earth seen from outside.

local yaw, pitch = 0, 0
local view = { bx = nil, by = nil, bz = nil }

local function setview(lat, lon)
	local rf = geom.horizon(lat or 0, lon or 0)
	local bx, by, bz = rf.bx, rf.by, rf.bz

	-- turn about the screen's own axes: up-down tilts, left-right
	-- spins, and both are about the axes the viewer sees.
	if pitch ~= 0 then
		by = geom.qrotate(by, bx, pitch)
		bz = geom.qrotate(bz, bx, pitch)
	end
	if yaw ~= 0 then
		bx = geom.qrotate(bx, bz, yaw)
		by = geom.qrotate(by, bz, yaw)
	end
	view.bx, view.by, view.bz = bx, by, bz
	view.rf = rf
end

-- a point in space to a pixel, with its depth: +z is toward the eye
local function project(p)
	local s = RPX / geom.RE

	return CX + (p.x * view.bx.x + p.y * view.bx.y + p.z * view.bx.z) * s,
	    CY - (p.x * view.by.x + p.y * view.by.y + p.z * view.by.z) * s,
	    p.x * view.bz.x + p.y * view.bz.y + p.z * view.bz.z
end

-- The disc never changes; only the basis it is viewed in. So each
-- sample's place on the sphere, its light and its limb are found once,
-- and a frame is nine multiplies and a lookup over what is left. STEP
-- takes one pixel in four and fills the square: this chip has no
-- double precision in hardware, so a quarter of the arithmetic is the
-- difference between a redraw and a wait.
local STEP = 2
local DPX, DPY, DVX, DVY, DVZ, DLIT, DLIMB = {}, {}, {}, {}, {}, {}, {}

do
	local n = 0

	for py = -RPX, RPX, STEP do
		local half = math.floor(math.sqrt(RPX * RPX - py * py))
		local vy = -py / RPX

		for px = -half, half, STEP do
			local vx = px / RPX
			-- clamped: the rounding that puts a pixel one inside
			-- the disc can still leave this below zero, and a
			-- nan here would index the map with a nan.
			local d = 1 - vx * vx - vy * vy
			local vz = d > 0 and math.sqrt(d) or 0

			n = n + 1
			DPX[n], DPY[n] = CX + px, CY + py
			DVX[n], DVY[n], DVZ[n] = vx, vy, vz
			DLIT[n] = -vx * 0.5 + vy * 0.5 + vz * 0.72
			DLIMB[n] = half - math.abs(px) < STEP + 1
		end
	end
	DPX.n = n
end

local function drawglobe(img)
	local bx, by, bz = view.bx, view.by, view.bz
	local bxx, bxy, bxz = bx.x, bx.y, bx.z
	local byx, byy, byz = by.x, by.y, by.z
	local bzx, bzy, bzz = bz.x, bz.y, bz.z
	local rect = memdraw.rect

	for i = 1, DPX.n do
		local vx, vy, vz = DVX[i], DVY[i], DVZ[i]
		local wy = vx * bxy + vy * byy + vz * bzy
		local wz = vx * bxz + vy * byz + vz * bzz
		local lit = DLIT[i]
		local c

		if DLIMB[i] then
			c = LIMB
		else
			local wx = vx * bxx + vy * byx + vz * bzx
			local sea = not landat(wz, math.atan(wy, wx))

			if lit < 0.25 then
				c = sea and SEADK or LANDDK
			elseif lit > 0.82 then
				c = (sea and SEA or LAND) + 0x102010
			else
				c = sea and SEA or LAND
			end
		end
		img:fill(rect(DPX[i], DPY[i], STEP, STEP), c)
	end
end

-- the meridians and parallels, drawn over the ball so a rotation reads
-- as a rotation rather than as the map sliding about
local function drawgrid(img)
	for lat = -60, 60, 30 do
		for lon = -180, 175, 5 do
			local p = geom.geodetic(lat, lon)
			local x, y, z = project(p)

			if z > 0 then
				img:set(math.floor(x + 0.5),
				    math.floor(y + 0.5), GRID)
			end
		end
	end
	for lon = -180, 150, 30 do
		for lat = -85, 85, 5 do
			local p = geom.geodetic(lat, lon)
			local x, y, z = project(p)

			if z > 0 then
				img:set(math.floor(x + 0.5),
				    math.floor(y + 0.5), GRID)
			end
		end
	end
end

local function dot(img, x, y, c, r)
	img:fill(memdraw.rect(math.floor(x + 0.5) - r,
	    math.floor(y + 0.5) - r, r * 2 + 1, r * 2 + 1), c)
end

local function satcolor(snr)
	local n = snr or 0

	if n >= 35 then
		return SATOK
	end
	return n > 0 and SATW or SAT
end

local SKYIMG = memdraw.image(S, S, BG, FMT)
local EARTHIMG = memdraw.image(S, S, BG, FMT)
local earthkey

-- The earth is the expensive half and changes only when the view does,
-- so it is kept and copied. A satellite moves every second and costs a
-- rectangle.
-- Coarse on purpose: a fix jitters in its last digits, and rebuilding
-- the globe for metres of wander is the whole cost of the app paid for
-- a ten-thousandth of a degree nobody can see.
local function earth(lat, lon)
	local key = ("%.2f.%.2f.%.3f.%.3f"):format(lat or 0, lon or 0, yaw,
	    pitch)

	if key ~= earthkey then
		EARTHIMG:fill(EARTHIMG:rect(), BG)
		drawglobe(EARTHIMG)
		drawgrid(EARTHIMG)
		earthkey = key
	end
	SKYIMG:draw(memdraw.pt(0, 0), EARTHIMG)
end

-- Everything at once, because a satellite behind the earth has to be
-- drawn before the earth and one in front after it.
local function plot(sky, lat, lon)
	setview(lat, lon)

	local pts = {}

	for _, s in ipairs(sky) do
		if s.azim and s.elev then
			local p = geom.skypoint(view.rf, s.azim, s.elev)
			local x, y, z = project(p)

			pts[#pts + 1] = { x = x, y = y, z = z, snr = s.snr }
		end
	end

	earth(lat, lon)

	-- Behind the earth and outside its outline: those are the ones
	-- still visible. A sphere hides exactly what its silhouette
	-- covers, so that is a distance from the centre and not a depth
	-- buffer.
	for _, p in ipairs(pts) do
		local dx, dy = p.x - CX, p.y - CY

		if p.z <= 0 and dx * dx + dy * dy > RPX * RPX then
			dot(SKYIMG, p.x, p.y, BEHIND, 1)
		end
	end

	-- where the receiver says it is, on the ball it is on
	if lat and lon then
		local x, y, z = project(geom.geodetic(lat, lon))

		if z > 0 then
			dot(SKYIMG, x, y, HERE, 1)
		end
	end

	for _, p in ipairs(pts) do
		if p.z > 0 then
			dot(SKYIMG, p.x, p.y, satcolor(p.snr), 1)
		end
	end

	fb.load({ x = (W - S) // 2, y = PLOTY, w = S, h = S },
	    memdraw.bytes(SKYIMG, SKYIMG:rect()), true, true, FMT)
end

-- ---- the numbers ----

local function hms(t)
	if not t then
		return "--:--:--"
	end
	return ("%02d:%02d:%02d"):format(t // 3600, (t % 3600) // 60,
	    math.floor(t % 60))
end

local function ymd(d)
	if not d then
		return "----------"
	end
	return ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
end

local function rows(f, st)
	local has = f and f.has

	text(2, ROW[0], has and "fix" or "no fix", has and OK or WARM, BG, 8)
	text(2 + 8 * FW, ROW[0], has and
	    ("%dd hdop %s"):format(f.fixtype or 0, tostring(f.hdop or "?")) or
	    "looking for sky", DIM, BG, COLS - 8)

	text(2, ROW[1], has and ("%.6f"):format(f.lat) or "", FG, BG, COLS)
	text(2, ROW[2], has and ("%.6f"):format(f.lon) or "", FG, BG, COLS)
	text(2, ROW[3], has and ("%s m   %s kn"):format(
	    f.alt and ("%.0f"):format(f.alt) or "--",
	    f.speed_knots and ("%.1f"):format(f.speed_knots) or "--") or "",
	    DIM, BG, COLS)

	text(2, ROW[4], ("%s %s UTC"):format(ymd(f and f.date),
	    hms(f and f.time)), FG, BG, COLS)

	local sky = (f and f.sky) or {}
	local heard = 0

	for _, s in ipairs(sky) do
		if (s.snr or 0) > 0 then
			heard = heard + 1
		end
	end
	text(2, ROW[5], ("%d in view, %d heard"):format(#sky, heard), DIM,
	    BG, COLS)

	if st then
		text(2, H - FH - 2, ("%s baud  %d ok  %d bad"):format(
		    tostring(st.baud), st.good or 0, st.bad or 0), DIM, BG,
		    COLS)
	end
	return sky
end

-- ---- asking ----

-- thread.rpc, not a send and a recv on thread.replyport: that port is
-- one per thread and is reused, so an answer that arrives after its
-- asker gave up is read as the reply to the next question.
local function ask(op)
	return thread.rpc(gps, { op = op }, 2000)
end

-- ---- the loop ----

local ev = prog.events()
local EVERY_MS = 1000
local running = true

fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)

-- what the scene looked like last, so one that has not changed is not
-- drawn again: the globe is a pixel loop and one message of its own
-- size, and neither is worth spending on an unmoved sky.
local function signature(sky, lat, lon)
	local parts = { ("%d.%d.%.2f.%.2f"):format(math.floor((lat or 0) * 100),
	    math.floor((lon or 0) * 100), yaw, pitch) }

	for _, s in ipairs(sky) do
		parts[#parts + 1] = ("%d.%d.%d.%d"):format(s.prn or 0,
		    s.snr or 0, s.elev or -1, s.azim or -1)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- the last position it had, so the earth stays where it was when the
-- fix drops rather than snapping back to (0N, 0E)
local atlat, atlon

local function frame()
	local f = ask("fix")
	local sky = rows(f, ask("stats"))

	if f and f.lat and f.lon then
		atlat, atlon = f.lat, f.lon
	end
	return sky, signature(sky, atlat, atlon)
end

local redraw = true

thread.spawn(function()
	local last

	while running do
		local sky, sig = frame()

		if redraw or sig ~= last then
			plot(sky, atlat, atlon)
			last, redraw = sig, false
		end
		thread.sleep(EVERY_MS)
	end
end)

-- the pointer is a port of its own and a thread of its own reads it:
-- alt cannot tell a port that hung up from a quiet one.
local point = prog.mouse()

if point then
	thread.spawn(function()
		local STEP = math.pi / 18	-- ten degrees a click

		while running do
			local _, _, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELLEFT) ~= 0 then
				yaw, redraw = yaw - STEP, true
			elseif (b & mouse.WHEELRIGHT) ~= 0 then
				yaw, redraw = yaw + STEP, true
			elseif (b & mouse.WHEELUP) ~= 0 then
				pitch, redraw = pitch - STEP, true
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				pitch, redraw = pitch + STEP, true
			end
		end
	end)
end

if ev then
	thread.spawn(function()
		while true do
			-- await, not recv: a dio that went away would park
			-- this one forever.
			local m, why = thread.await(ev)

			if why then
				break
			end
			if type(m) == "string" and (m == "q" or m == "\27") then
				break
			end
		end
		running = false
	end)
end

thread.run()
