-- clock: the time, big enough to read across a room.
-- Touch the screen to turn it over: digital, or the face.

-- Digital draws with fill() alone -- a seven-segment digit is seven
-- rectangles. A hand at an angle is not, so the face is composed in a
-- memdraw image and loaded in one go.

-- sys.time() is nil until task/timed.lua has set it from the network.
-- Until then this draws the epoch, which is a clock that is wrong
-- rather than a clock that is missing.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local memdraw = require("memdraw")
local time = require("time")

local fb = prog.screen()

if not fb then
	io.stderr:write("clock: no framebuffer on this machine\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h

-- the screen's own format where memdraw has it, so the face reaches
-- the glass without being converted on the way. A screen naming
-- something else -- efi reports bltonly and bitmask -- gets bgrx,
-- which every screen here takes.
local FMT = memdraw.bpp(mode.format) and mode.format or memdraw.BGRX

local DIGITAL = {
	bg = 0x000000,
	fg = 0xff2418,
}
local FACE = {
	bg = 0x101014,
	dial = 0xf2f0e8,
	rim = 0x8a8880,
	tick = 0x303038,
	hand = 0x1a1a20,
	second = 0xd02018,
}

local face = false		-- which of the two is on the glass
local faceok = true		-- until the screen will not give it images
local visible = true		-- false while another app is in front

-- ---- seven segment ----
--
-- a..g in the usual order: top, upper right, lower right, bottom,
-- lower left, upper left, middle.
local SEG = {
	["0"] = "abcdef",  ["1"] = "bc",     ["2"] = "abdeg",
	["3"] = "abcdg",   ["4"] = "bcfg",   ["5"] = "acdfg",
	["6"] = "acdefg",  ["7"] = "abc",    ["8"] = "abcdefg",
	["9"] = "abcdfg",  ["-"] = "g",      [" "] = "",
}

local ORDER = { "a", "b", "c", "d", "e", "f", "g" }

local function segrects(x, y, w, h, t)
	local v = (h - 3 * t) // 2

	return {
		a = memdraw.rect(x + t, y, w - 2 * t, t),
		b = memdraw.rect(x + w - t, y + t, t, v),
		c = memdraw.rect(x + w - t, y + 2 * t + v, t, v),
		d = memdraw.rect(x + t, y + 2 * t + 2 * v, w - 2 * t, t),
		e = memdraw.rect(x, y + 2 * t + v, t, v),
		f = memdraw.rect(x, y + t, t, v),
		g = memdraw.rect(x + t, y + t + v, w - 2 * t, t),
	}
end

-- the box a glyph's lit segments actually cover. e and f are the left
-- column, b and c the right, a, d and g the span between: a 1 is bc
-- alone and sits hard right, a 3 has no left column at all, and both
-- read as uneven spacing between the pairs.
local XSPAN = {
	e = { 0, 0 }, f = { 0, 0 },
	a = { 1, 1 }, d = { 1, 1 }, g = { 1, 1 },
	b = { 2, 2 }, c = { 2, 2 },
}

local function ink(on, w, t)
	local lo, hi = 2, 0

	for s in on:gmatch(".") do
		local z = XSPAN[s]

		if z then
			lo = math.min(lo, z[1])
			hi = math.max(hi, z[2])
		end
	end
	if lo > hi then
		return 0, w
	end

	local edge = { [0] = 0, [1] = t, [2] = w - t }
	local far = { [0] = t, [1] = w - t, [2] = w }

	return edge[lo], far[hi]
end

-- centred in its cell, so the gaps between pairs are the gaps that
-- show. The cell is cleared first: a glyph drawn at one offset cannot
-- be erased by the segments of one drawn at another.
local function digit(ch, x, y, w, h, t)
	local on = SEG[ch] or ""
	local l, r = ink(on, w, t)
	local dx = (w - (r - l)) // 2 - l

	fb.fill(memdraw.rect(x, y, w, h), DIGITAL.bg)

	local rects = segrects(x + dx, y, w, h, t)

	for _, s in ipairs(ORDER) do
		if on:find(s, 1, true) then
			fb.fill(rects[s], DIGITAL.fg)
		end
	end
end

-- ---- digital layout ----
--
-- sized off the window, so this is one program on a 320x240 panel and
-- on a screen.
local dw = W // 12
local dh = dw * 2
local dt = math.max(2, dw // 6)
local gap = math.max(3, dw // 3)
local cw = dw // 2
local dy = (H - dh) // 2 - dh // 4

local cells = {}

do
	-- summed rather than reckoned: six digits, two colons and the
	-- seven gaps between them, which is not 6*dw + 5*gap + 2*cw
	local total = 6 * dw + 2 * cw + 7 * gap
	local x = (W - total) // 2

	for i = 1, 8 do
		local colon = i == 3 or i == 6

		cells[i] = { x = x, colon = colon, w = colon and cw or dw }
		x = x + cells[i].w + gap
	end
end

local datew = math.max(3, dw // 3)
local dateh = datew * 2
local datey = dy + dh + dh // 4

local function colon(c, lit)
	local s = dt
	local x = c.x + (c.w - s) // 2
	local y = dy + dh // 3

	fb.fill(memdraw.rect(x, y, s, s), lit and DIGITAL.fg or DIGITAL.bg)
	fb.fill(memdraw.rect(x, y + dh // 3, s, s),
	    lit and DIGITAL.fg or DIGITAL.bg)
end

-- what is on the glass, so a tick redraws only what changed: a second
-- is one digit, and every fill is a message.
local shown, shownday = {}, {}

local function paint_digital(now, force)
	local d = time.utc(now)
	local txt = ("%02d:%02d:%02d"):format(d.hour, d.min, d.sec)

	for i = 1, 8 do
		local c = cells[i]
		local ch = txt:sub(i, i)

		if force or shown[i] ~= ch then
			if c.colon then
				colon(c, true)
			else
				digit(ch, c.x, dy, dw, dh, dt)
			end
			shown[i] = ch
		end
	end

	local day = ("%04d-%02d-%02d"):format(d.year, d.month, d.day)

	local t = math.max(1, datew // 5)
	local g = math.max(1, datew // 3)
	local x = (W - (#day * (datew + g) - g)) // 2

	for i = 1, #day do
		local ch = day:sub(i, i)

		if force or shownday[i] ~= ch then
			digit(ch, x, datey, datew, dateh, t)
			shownday[i] = ch
		end
		x = x + datew + g
	end
end

-- ---- the face ----
--
-- One image, redrawn whole each second and loaded once. The hands sweep
-- everywhere, so there is no smaller rectangle that changed, and a
-- band of rows is one message where a stepped line would be hundreds.
local D = math.min(W, H) - 8
local FX, FY = (W - D) // 2, (H - D) // 2
local R = D // 2

-- Two images the screen holds: the pristine dial, and the one the hands
-- go on. The dial crosses the port once, when it is built. After that a
-- tick is a blit, three lines and a blit -- five messages, none of them
-- carrying a pixel.
local dialid, workid

local function disc(img, cx, cy, rad, color)
	for y = -rad, rad do
		local half = math.floor(math.sqrt(rad * rad - y * y))

		img:fill(memdraw.rect(cx - half, cy + y, half * 2 + 1, 1),
		    color)
	end
end

-- a hand as a run of squares along its angle. In an image, so this
-- costs no messages however many steps it takes.
local function hand(img, cx, cy, angle, len, wide, color)
	local dx, dy2 = math.sin(angle), -math.cos(angle)
	local half = wide // 2

	for i = 0, len do
		local x = math.floor(cx + dx * i + 0.5)
		local y = math.floor(cy + dy2 * i + 0.5)

		img:fill(memdraw.rect(x - half, y - half, wide, wide), color)
	end
end

local RIMR = R - 1
local DIALR = R - math.max(2, R // 24)

local function makedial()
	local img = memdraw.image(D, D, FACE.bg, FMT)

	disc(img, R, R, RIMR, FACE.rim)
	disc(img, R, R, DIALR, FACE.dial)
	for i = 0, 11 do
		local a = i * math.pi / 6
		local wide = (i % 3 == 0) and math.max(3, R // 12)
		    or math.max(2, R // 24)
		local from = (i % 3 == 0) and R * 0.80 or R * 0.86

		hand(img, R + math.sin(a) * from, R - math.cos(a) * from, a,
		    R * 0.92 - from, wide, FACE.tick)
	end
	return img
end

local DRECT = memdraw.rect(0, 0, D, D)
local FPT = memdraw.pt(FX, FY)
local CENTRE = memdraw.pt(R, R)

-- composed here and handed over once, then dropped: the copy that
-- matters from now on is the screen's.
local function makeimages()
	local err

	dialid, err = fb.alloc(D, D, FMT, FACE.bg)
	workid = dialid and fb.alloc(D, D, FMT, FACE.bg)
	if not dialid or not workid then
		warn("@on")
		warn("clock: no images from the screen: " .. tostring(err))
		return false
	end

	local img = makedial()

	fb.load(DRECT, img:bytes(DRECT), true, false, FMT, dialid)
	return true
end

local function dropimages()
	if dialid then
		fb.free(dialid)
		fb.free(workid)
		dialid, workid = nil, nil
	end
end

-- where a hand's tip lands, in the dial's own coordinates
local function tip(angle, len)
	return memdraw.pt(math.floor(R + math.sin(angle) * len + 0.5),
	    math.floor(R - math.cos(angle) * len + 0.5))
end

local function paint_face(now)
	if not dialid and not makeimages() then
		return
	end

	fb.draw(workid, dialid)

	local d = time.utc(now)
	local sec = d.sec * math.pi / 30
	local min = (d.min + d.sec / 60) * math.pi / 30
	local hr = ((d.hour % 12) + d.min / 60) * math.pi / 6

	fb.line(workid, CENTRE, tip(hr, R * 0.52),
	    math.max(3, R // 14), FACE.hand)
	fb.line(workid, CENTRE, tip(min, R * 0.76),
	    math.max(3, R // 20), FACE.hand)
	fb.line(workid, CENTRE, tip(sec, R * 0.84),
	    math.max(1, R // 40), FACE.second)
	fb.line(workid, CENTRE, CENTRE, math.max(4, R // 11), FACE.hand)
	fb.draw(nil, workid, DRECT, FPT)
end

-- ---- both, and the switch between them ----

-- A face is loaded as several bands and yields between them. Without
-- this, a switch arriving mid-load clears the screen and the remaining
-- bands land on top of whatever replaced it.
local painting = require("sync.lock").new()

-- flip: turn the clock over first. clear: wipe before drawing.
local function paint(force, flip, wipe)
	painting:lock()

	if flip then
		face = not face
	end
	if wipe or flip then
		fb.fill(memdraw.rect(0, 0, W, H),
		    face and FACE.bg or DIGITAL.bg)
		shown, shownday = {}, {}
		force = true
	end
	-- the screen is holding two images a digital clock is not showing
	if not face then
		dropimages()
	end

	-- the epoch until something says otherwise: a clock reading
	-- 1970 is wrong in a way a person can see, and a blank one is
	-- not.
	local now = sys.time() or 0
	local ok, err = pcall(face and paint_face or paint_digital, now, force)

	painting:unlock()
	-- reported and carried on rather than raised. This runs in a
	-- thread, so raising kills the one that ticks and stops the clock
	-- for good -- a face that cannot be drawn should cost the face.
	if not ok then
		warn("@on")
		warn("clock: " .. tostring(err))
		dropimages()
		face = false
	end
end

paint(nil, false, true)


-- a touch anywhere turns the clock over. Press, not release, so it
-- answers under the finger.
local mouse = prog.mouse()
local mousemod = require("mouse")
local down = false

local function ontap(b)
	-- the wheel is buttons 8 and 16 on a T-Deck's trackball, and
	-- rolling it is not a tap
	local tap = b and b % 8 ~= 0 and b % 8 or 0

	if tap ~= 0 and not down then
		paint(nil, true)
	end
	down = tap ~= 0
end

-- off a window system the pointer is read directly. In one the records
-- arrive with the window's own state, and the loop below takes them.
if mouse then
	thread.spawn(function()
		while true do
			local _, _, b = mouse.read()

			if not b then
				break
			end
			ontap(b)
		end
	end)
end

-- brought back to the front: whatever was there in between is not ours
-- to know, so repaint the lot.
--
-- Behind another app the face stays in the window, so a tick spent
-- painting is a tick spent on a second nobody is looking at. Coming
-- back shows the time it stopped at, which one paint corrects.
local ev = prog.events()

if ev then
	thread.spawn(function()
		while true do
			local m, why = thread.await(ev)

			if why then
				break
			end
			local _, _, b = mousemod.parse(m)

			if b then
				ontap(b)
				goto continue
			end
			if type(m) ~= "table" or m.t ~= "win" then
				goto continue
			end
			if m.state == "redraw" then
				visible = true
				paint(nil, false, true)
			elseif m.state == "visible" then
				visible = true
				paint(nil, false, false)
			elseif m.state == "hidden" then
				visible = false
			end
			::continue::
		end
	end)
end

-- a line on stdin gives the screen back, which is how a program started
-- from the prompt ends. Under dio there is none and the tray closes it.
local stdin = prog.stdin()

if stdin then
	thread.spawn(function()
		stdin:read("l")
		dropimages()
		fb.fill(memdraw.rect(0, 0, W, H), 0x000000, true)
		os.exit(0)
	end)
end

thread.spawn(function()
	while true do
		-- nothing to draw on behind another app: the window system
		-- drops what it is sent, so painting is a message built to
		-- be thrown away.
		if visible then
			paint(false)
		end
		-- to the next second, not every 1000ms: a fixed interval
		-- drifts, and a clock that skips a second then shows two
		-- is worse than one that is late.
		thread.sleep(1000 - sys.uptime_ms() % 1000)
	end
end)

thread.run()
