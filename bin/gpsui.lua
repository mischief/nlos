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
local S = math.min(H - PLOTY - 4, W - 4)
local CX, CY = S // 2, S // 2
-- as much of the square as the satellites leave: a ring of them sits
-- outside the limb, and a coastline needs the pixels
local RPX = S // 2 - 8

local SEA, LAND = 0x14498a, 0x2f7a44
local SEADK, LANDDK = 0x081f3c, 0x123018
local LIMB, GRID = 0x6fa8ff, 0x1a2a44
local HERE = 0xffd020
local SAT, SATW, SATOK, BEHIND = 0xd03030, 0xd0a020, 0x40d060, 0x304050

-- 96 by 48 cells of land or sea, rasterised from continent outlines by
-- tools/mkworld.lua. Sampling one bit is what the board can afford per
-- pixel; testing a polygon is not.
local NX, NY = 192, 96
local WORLDHEX =
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"0000000000000000000000000000000000000000003f0000000000000000" ..
	"00000000000000000000000000007ffff800000000000000000000000000" ..
	"00000000000000007ffff800000000000000000000000000000000000000" ..
	"00003ffff80000000000000006000000000000000000000000003ffff800" ..
	"000000000001ffffffe0000000000000000000003ffff80000000000007f" ..
	"fffffffff80000000000000004003ffff800000000000ffffffffffffffc" ..
	"003fc000003fdf001ffff800000600007ffffffffffffffe00fffffff3ff" ..
	"ffc01fffe000001ff0fffffffffffffffffe01ffffffffffffe00fff8000" ..
	"007ffffffffffffffffffff001fffffffffffff007fc00000180ffffffff" ..
	"ffffffffff8001fffffffff803f803f000000701fffffffffffffffffc00" ..
	"01fffffffff803e0018000001e01ffffffffffffffff800001fffffffff8" ..
	"03e0000000000e03fffffffffffffff8000000f001fffff803e000000006" ..
	"0c03fffffffffffffff800000080007ffff803e0000000060c03ffffffff" ..
	"fffffff000000000003ffff803ff8000000e0fffffffffffffffffe00000" ..
	"0000001ffff803ffc000000e0fffffffffffffffff8000000000000fffff" ..
	"ffff8000000fffffffffffffffffff00000000000007fffffffe0000001f" ..
	"fffffffffffffffffe00000000000007fffffffc0000001ffffe0387ffff" ..
	"fffffc00000000000007fffffff00000001ff0fe0387fffffffffc000000" ..
	"00000003ffffffe00000001f803e0380fffffffff018000000000003ffff" ..
	"ffc00000001f0007ff003fffffffc038000000000003ffffff800000001e" ..
	"0000f80007ffffff8070000000000003ffffff80000000000000000003ff" ..
	"ffff80e0000000000003ffffff00000000018000000001ffffff81c00000" ..
	"00000000fffffe0000000007fe00000000ffffff820000000000000023ff" ..
	"fe000000001fffff8000007fffff800000000000000003fe04000000003f" ..
	"ffffc000003fffff800000000000000003f800000000003fffffc000001f" ..
	"ffff000000000000000003f000000000007fffffc0000007fffe00000000" ..
	"0000000003f000000000007fffffc0000003fffe000000000000000001f0" ..
	"0000000000ffffffc0000000fff0000000000000000000f00000000001ff" ..
	"ffffc00000001fc00000000000000000003c0000000001ffffffc0000000" ..
	"0f800000000000000000000f0000000001ffffffc00000000f8000000000" ..
	"0000000000007800000001ffffffc0000000078000000000000000000000" ..
	"3800000000fffffffe0000000100000000000000000000001c000000007f" ..
	"ffffffe00000000000000000000000000000067f8000003fffffffe00000" ..
	"00000000000000000000000007ffe000001fffffffc00000000000000000" ..
	"00000000000007fff80000007fffffc00000000000000000000000000000" ..
	"07fffc0000000fffffc000001f000000000000000000000007ffff000000" ..
	"07ffffc000000ff80000000000000000000007ffffc0000007ffff800000" ..
	"07fff800000000000000000007ffffe0000007ffff80000007ffffe00000" ..
	"00000000000007fffff8000007ffff000000007ffff80000000000000000" ..
	"07fffff8000007ffff0000000007fffc000000000000000003fffff80000" ..
	"07fffe00000000000007000000000000000003fffff0000003fffe000000" ..
	"00000000000000000000000001fffff0000003fffc000000000007f00000" ..
	"00000000000000fffff0000003fffd80000000001ff80000000000000000" ..
	"00ffffe0000003fff9e0000000007ff80000000000000000007fffc00000" ..
	"03fff9c000000000fffc0000000000000000003fff80000001fff1c00000" ..
	"0003fffc0000000000000000001fff00000001fff0c000000007fffe0000" ..
	"000000000000001ffe00000001ffe0400000000fffff0000000000000000" ..
	"003ffc00000000ffc0000000000fffff0000000000000000003ff8000000" ..
	"00ff800000000007ffff8000000000000000003ff000000000ff00000000" ..
	"0007ffff8000000000000000003fe0000000007e000000000007ffff8000" ..
	"000000000000003fc0000000007c000000000007e3ff8000000000000000" ..
	"003f800000000020000000000001007f0000000000000000003f00000000" ..
	"0000000000000000000f0000000000000000003f00000000000000000000" ..
	"000000000004000000000000003e0000000000000000000000000000000c" ..
	"000000000000007c00000000000000000000000000000010000000000000" ..
	"007c00000000000000000000000000000000000000000000007800000000" ..
	"000000000000000000000000000000000000007800000000000000000000" ..
	"00000000000000000000000000f000000000000000000000000000000000" ..
	"00000000000000f000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000000000000000000000000000000000000000000000000000" ..
	"000000000000ffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ..
	"ffffffffffffffffffffffffffffffffffffffffffffffff"

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

-- The camera rides the equator and looks at the axis: north is up the
-- screen, the poles stay top and bottom, and turning runs longitude
-- past. Starting at the receiver's own meridian, so what is in front
-- on the first frame is where the machine is.
local yaw = 0
local view = { bx = nil, by = nil, bz = nil }

local function setview(lat, lon)
	-- the observer's frame, never turned: a bearing and an elevation
	-- are measured from where the receiver is, not from wherever the
	-- globe has been rolled to.
	local rf = geom.horizon(lat or 0, lon or 0)
	local a = (lon or 0) * geom.DEG + yaw
	local sa, ca = math.sin(a), math.cos(a)

	view.bx = geom.Vec3(-sa, ca, 0)		-- east, across the screen
	view.by = geom.Vec3(0, 0, 1)		-- the pole, up it
	view.bz = geom.Vec3(ca, sa, 0)		-- and out toward the eye
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
local DROW = {}

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
		DROW[n] = true		-- the last sample of this row
	end
	DPX.n = n
end

-- A rectangle a sample is what the picture asks for and not what it
-- costs: an ocean is a long run of one colour, and the measurement says
-- the frame is the calls rather than the arithmetic -- 7.6% of it was
-- floating point. So a run of one colour along a row goes out as one
-- rectangle, and DROW says where a row ends.
local function drawglobe(img, yield)
	local bx, by, bz = view.bx, view.by, view.bz
	local bxx, bxy, bxz = bx.x, bx.y, bx.z
	local byx, byy, byz = by.x, by.y, by.z
	local bzx, bzy, bzz = bz.x, bz.y, bz.z
	local fill, rect = img.fill, memdraw.rect
	local runc, runx, runn = nil, 0, 0

	for i = 1, DPX.n do
		local vx, vy, vz = DVX[i], DVY[i], DVZ[i]
		local wy = vx * bxy + vy * byy + vz * bzy
		local wz = vx * bxz + vy * byz + vz * bzz
		local c

		if DLIMB[i] then
			c = LIMB
		else
			local wx = vx * bxx + vy * byx + vz * bzx
			local sea = not landat(wz, math.atan(wy, wx))
			local lit = DLIT[i]

			if lit < 0.25 then
				c = sea and SEADK or LANDDK
			elseif lit > 0.82 then
				c = (sea and SEA or LAND) + 0x102010
			else
				c = sea and SEA or LAND
			end
		end

		if c == runc then
			runn = runn + STEP
		else
			if runc then
				fill(img, rect(runx, DPY[i - 1], runn, STEP),
				    runc)
			end
			runc, runx, runn = c, DPX[i], STEP
		end
		if DROW[i] then
			fill(img, rect(runx, DPY[i], runn, STEP), runc)
			runc = nil
			-- a row at a time, so a render begun for a turn
			-- nobody asked for yet still lets the panel answer
			-- one that was
			if yield then
				thread.yield()
			end
		end
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


-- ---- the earth, kept by the draw server ----
--
-- Sixteen positions and no more, which is as much of a turn as this
-- reads at 96 pixels across. Each is drawn once, handed over as an
-- image, and afterwards is a message naming it: the pixels stop
-- crossing the port, so a turn already seen costs nothing.
local STEPS = 16
local TURNSTEP = 2 * math.pi / STEPS
local step = 0
local WINX, WINY = (W - S) // 2, PLOTY
local EARTHIMG = memdraw.image(S, S, BG, FMT)
local kept = {}		-- step -> the id the server knows it by
local keptat		-- and the position they were all drawn for

local function forget()
	for i, id in pairs(kept) do
		pcall(fb.free, id, false)
		kept[i] = nil
	end
end

-- Coarse on purpose: a fix jitters in its last digits, and throwing
-- away sixteen globes for metres of wander would cost the whole app
-- for a ten-thousandth of a degree nobody can see.
local function globe(lat, lon)
	local at = ("%.2f.%.2f"):format(lat or 0, lon or 0)

	if at ~= keptat then
		forget()
		keptat = at
	end

	return kept[step]
end

-- Draw one position and give it to the server. `bg` yields a row at a
-- time, which is what lets a turn nobody asked for yet be built while
-- the panel still answers the one that was.
local function render(which, lat, lon, bg)
	if kept[which] then
		return kept[which]
	end

	local was = step

	step = which
	setview(lat, lon)
	EARTHIMG:fill(EARTHIMG:rect(), BG)
	drawglobe(EARTHIMG, bg)
	drawgrid(EARTHIMG)
	step = was

	local id = fb.alloc(S, S, FMT, BG)

	if not id then
		return nil
	end
	if not fb.load({ x = 0, y = 0, w = S, h = S },
	    memdraw.bytes(EARTHIMG, EARTHIMG:rect()), true, true, FMT, id) then
		pcall(fb.free, id, false)
		return nil
	end
	kept[which] = id
	return id
end

-- The turns a roll can reach next. Built behind the panel so the first
-- click in either direction is a message rather than a wait; two is as
-- far ahead as is worth going, since a third arrives before a hand
-- gets there.
local AHEAD = 2

local function prefetch(lat, lon)
	for d = 1, AHEAD do
		for _, w in ipairs({ (step + d) % STEPS, (step - d) % STEPS }) do
			if not kept[w] then
				render(w, lat, lon, true)
				return true
			end
		end
	end
	return false
end

-- Everything drawn is heard, so the colour is how well: red is one the
-- receiver can barely make out, green one it can fix on.
local function satcolor(snr)
	local n = snr or 0

	if n >= 35 then
		return SATOK
	end
	return n >= 20 and SATW or SAT
end

local function dot(x, y, c)
	fb.fill({ x = WINX + math.floor(x + 0.5) - 1,
	    y = WINY + math.floor(y + 0.5) - 1, w = 3, h = 3 }, c, false)
end

-- The globe goes down first and erases the frame before it, so the
-- satellites are drawn after and nothing has to be rubbed out.
local function plot(sky, lat, lon)
	yaw = step * TURNSTEP
	setview(lat, lon)

	local id = globe(lat, lon) or render(step, lat, lon, false)

	if id then
		fb.draw(nil, id, { x = 0, y = 0, w = S, h = S },
		    { x = WINX, y = WINY }, false)
	end

	for _, s in ipairs(sky) do
		if s.azim and s.elev then
			local x, y, z = project(geom.skypoint(view.rf, s.azim,
			    s.elev))
			local dx, dy = x - CX, y - CY

			-- a sphere hides exactly what its outline covers,
			-- so that is a distance and not a depth buffer
			if z > 0 then
				dot(x, y, satcolor(s.snr))
			elseif dx * dx + dy * dy > RPX * RPX then
				dot(x, y, BEHIND)
			end
		end
	end

	if lat and lon then
		local x, y, z = project(geom.geodetic(lat, lon))

		if z > 0 then
			dot(x, y, HERE)
		end
	end
	if fb.sync then
		fb.sync()
	end
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

local function rows(f)
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

	-- everything gpsd sends is heard, so the count is the list
	local sky = (f and f.sky) or {}

	text(2, ROW[5], ("%d heard, %d used"):format(#sky, f and f.nsats or 0),
	    DIM, BG, COLS)
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
	local parts = { ("%d.%d.%.3f"):format(math.floor((lat or 0) * 100),
	    math.floor((lon or 0) * 100), step) }

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
	local sky = rows(f)

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

		-- One turn ahead per pass, and only when nothing else is
		-- waiting: a click that arrives mid-build is answered on
		-- the next row rather than after the whole globe.
		if not redraw then
			prefetch(atlat, atlon)
		end
		thread.sleep(EVERY_MS)
	end
end)

-- the pointer is a port of its own and a thread of its own reads it:
-- alt cannot tell a port that hung up from a quiet one.
-- how long a burst from one roll of the ball lasts, near enough
local TURNGAP = 350
local lastturn = 0
local point = prog.mouse()

if point then
	thread.spawn(function()
		-- one of the sixteen a click, so every position a roll can
		-- reach is one the server already holds after the first lap

		while running do
			local _, _, b = point.read()

			if not b then
				return
			end
			-- Both axes turn the one we have: the ball is
			-- rolled whichever way comes to hand, and a roll
			-- that did nothing would read as a dead control.
			local d = 0

			if (b & (mouse.WHEELLEFT | mouse.WHEELUP)) ~= 0 then
				d = -1
			elseif (b & (mouse.WHEELRIGHT | mouse.WHEELDOWN)) ~= 0
			    then
				d = 1
			end

			-- One turn per flick. A trackball is not a detented
			-- wheel: rolling it once sends a burst of records,
			-- and a step for each of them spun the earth half
			-- way round. The rest of the burst is dropped.
			local now = sys.uptime_ms()

			if d ~= 0 and now - lastturn >= TURNGAP then
				lastturn = now
				step, redraw = (step + d) % STEPS, true
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
