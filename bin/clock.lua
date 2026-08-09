-- clock: the time, big enough to read across a room.
-- Touch the screen to turn it over: digital, or the face.

-- Digital draws with fill() alone -- a seven-segment digit is seven
-- rectangles. A hand at an angle is not, so the face is composed in a
-- memdraw image and loaded in one go.

-- sys.time() is nil until task/timed.lua has set it, and this shows
-- dashes rather than a confident 1970.

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

-- an unlit segment is painted background rather than skipped, so a
-- digit replacing another erases what it does not light.
local function digit(ch, x, y, w, h, t)
	local on = SEG[ch] or ""
	local r = segrects(x, y, w, h, t)

	for _, s in ipairs(ORDER) do
		fb.fill(r[s], on:find(s, 1, true) and DIGITAL.fg or DIGITAL.bg)
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
	local txt = "  :  :  "

	if now then
		local d = time.utc(now)

		txt = ("%02d:%02d:%02d"):format(d.hour, d.min, d.sec)
	end

	for i = 1, 8 do
		local c = cells[i]
		local ch = txt:sub(i, i)

		if force or shown[i] ~= ch then
			if c.colon then
				colon(c, now ~= nil)
			else
				digit(ch, c.x, dy, dw, dh, dt)
			end
			shown[i] = ch
		end
	end

	local day = "          "

	if now then
		local d = time.utc(now)

		day = ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
	end

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
local dial				-- made on first use, kept after

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

local function makedial()
	local img = memdraw.image(D, D, FACE.bg)

	disc(img, R, R, R - 1, FACE.rim)
	disc(img, R, R, R - math.max(2, R // 24), FACE.dial)
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

local FRECT = memdraw.rect(FX, FY, D, D)

local function paint_face(now)
	dial = dial or makedial()

	local img = memdraw.image(D, D, FACE.bg)

	img:draw(memdraw.pt(0, 0), dial, dial:rect())

	if now then
		local d = time.utc(now)
		local sec = d.sec * math.pi / 30
		local min = (d.min + d.sec / 60) * math.pi / 30
		local hr = ((d.hour % 12) + d.min / 60) * math.pi / 6

		hand(img, R, R, hr, R * 0.52, math.max(3, R // 14), FACE.hand)
		hand(img, R, R, min, R * 0.76, math.max(3, R // 20), FACE.hand)
		hand(img, R, R, sec, R * 0.84, math.max(1, R // 40),
		    FACE.second)
	end
	disc(img, R, R, math.max(2, R // 22), FACE.hand)

	fb.load(FRECT, img:bytes(img:rect()), false, true)
end

-- ---- both, and the switch between them ----

local function clear()
	fb.fill(memdraw.rect(0, 0, W, H), face and FACE.bg or DIGITAL.bg)
	shown, shownday = {}, {}
end

local function paint(force)
	local now = sys.time()

	if face then
		paint_face(now)
	else
		paint_digital(now, force)
	end
end

clear()
paint(true)

local N = prog.ns()

-- a touch anywhere turns the clock over. Press, not release, so it
-- answers under the finger.
local mouse = N and N:open("/dev/mouse", "r")

if mouse then
	thread.spawn(function()
		local down = false

		while true do
			local rec = mouse:read(49)

			if not rec then
				break
			end

			local b = tonumber(rec:match(
			    "^m%s*%-?%d+%s+%-?%d+%s+(%-?%d+)") or "")
			-- the wheel is buttons 8 and 16 on a T-Deck's
			-- trackball, and rolling it is not a tap
			local tap = b and b % 8 ~= 0 and b % 8 or 0

			if tap ~= 0 and not down then
				face = not face
				clear()
				paint(true)
			end
			down = tap ~= 0
		end
		mouse:close()
	end)
end

-- brought back to the front: whatever was there in between is not ours
-- to know, so repaint the lot.
local wctl = N and N:open("/dev/wctl", "r")

if wctl then
	thread.spawn(function()
		while true do
			local s = wctl:read(16)

			if not s then
				break
			end
			if s:match("redraw") then
				clear()
				paint(true)
			end
		end
		wctl:close()
	end)
end

-- a line on stdin gives the screen back, which is how a program started
-- from the prompt ends. Under dio the tray closes it instead.
thread.spawn(function()
	io.read("l")
	fb.fill(memdraw.rect(0, 0, W, H), 0x000000, true)
	os.exit(0)
end)

thread.spawn(function()
	while true do
		paint(false)
		-- to the next second, not every 1000ms: a fixed interval
		-- drifts, and a clock that skips a second then shows two
		-- is worse than one that is late.
		thread.sleep(1000 - sys.uptime_ms() % 1000)
	end
end)

thread.run()
