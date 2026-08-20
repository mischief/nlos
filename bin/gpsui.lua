-- gpsui: where the machine is, on the panel. q or the tray leaves.
--
-- A sky plot around a globe: north is up, azimuth runs clockwise, and
-- elevation is how close to the earth a satellite sits -- overhead
-- rests on the limb, the horizon is out at the ring.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")
local memdraw = require("memdraw")

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
local RING = S // 2 - 3
local R = math.max(8, (RING * 42) // 100)

local SEA, LAND, LIMB = 0x1b3a6b, 0x2e7d4f, 0x4a7ad0
local HORIZON = 0x243044
local SAT, SATW, SATOK = 0xd03030, 0xd0a020, 0x40d060

-- Crude on purpose: a few caps of land over a shaded sea reads as the
-- earth at this size, where a coastline would read as noise.
local LANDMASS = {
	{ -0.28, -0.30, 0.34 }, { 0.14, -0.12, 0.36 },
	{ -0.02, 0.38, 0.28 }, { 0.48, 0.26, 0.22 },
}

local function inland(nx, ny)
	for _, c in ipairs(LANDMASS) do
		local dx, dy = nx - c[1], ny - c[2]

		if dx * dx + dy * dy < c[3] * c[3] then
			return true
		end
	end
	return false
end

-- Built once and kept: the globe and the horizon do not change, and
-- rebuilding a lit sphere per frame would cost more than the fix.
local function makeglobe()
	local img = memdraw.image(S, S, BG, FMT)

	for i = 0, 71 do
		local a = i * math.pi / 36

		img:set(CX + math.floor(math.sin(a) * RING + 0.5),
		    CY - math.floor(math.cos(a) * RING + 0.5), HORIZON)
	end

	for dy = -R, R do
		local half = math.floor(math.sqrt(R * R - dy * dy))

		for dx = -half, half do
			local nx, ny = dx / R, dy / R
			-- lit from the upper left, so the limb on the far
			-- side falls into shadow and the ball reads round
			local z = math.sqrt(math.max(0, 1 - nx * nx - ny * ny))
			local lit = -nx * 0.55 - ny * 0.55 + z * 0.62
			local c = inland(nx, ny) and LAND or SEA

			if half - math.abs(dx) < 1 then
				c = LIMB
			elseif lit < 0.10 then
				c = (c & 0xfcfcfc) >> 2
			elseif lit < 0.40 then
				c = (c & 0xfefefe) >> 1
			elseif lit > 0.80 then
				c = c + 0x141c28
			end
			img:set(CX + dx, CY + dy, c)
		end
	end
	return img
end

local EARTH = makeglobe()
local SKY = memdraw.image(S, S, BG, FMT)

local function satcolor(snr)
	local n = snr or 0

	if n >= 35 then
		return SATOK
	end
	return n > 0 and SATW or SAT
end

-- A satellite with no azimuth has never been located, only heard of,
-- so it is not placed: a dot at a made-up bearing is worse than none.
local function plot(sky)
	SKY:draw(memdraw.pt(0, 0), EARTH)

	for _, s in ipairs(sky) do
		if s.azim and s.elev then
			local a = math.rad(s.azim)
			local rad = R + (1 - math.min(s.elev, 90) / 90) *
			    (RING - R)
			local x = CX + math.floor(math.sin(a) * rad + 0.5)
			local y = CY - math.floor(math.cos(a) * rad + 0.5)

			SKY:fill(memdraw.rect(x - 1, y - 1, 3, 3),
			    satcolor(s.snr))
		end
	end
	fb.load({ x = (W - S) // 2, y = PLOTY, w = S, h = S },
	    memdraw.bytes(SKY, SKY:rect()), true, true, FMT)
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

-- what the sky looked like last, so a plot that has not changed is not
-- sent again: the globe is one message of the window's whole width.
local function signature(sky)
	local parts = {}

	for _, s in ipairs(sky) do
		parts[#parts + 1] = ("%d.%d.%d.%d"):format(s.prn or 0,
		    s.snr or 0, s.elev or -1, s.azim or -1)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

thread.spawn(function()
	local last

	while running do
		local sky = rows(ask("fix"), ask("stats"))
		local sig = signature(sky)

		if sig ~= last then
			plot(sky)
			last = sig
		end
		thread.sleep(EVERY_MS)
	end
end)

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
