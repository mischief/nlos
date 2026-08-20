-- gpsui: where the machine is, on the panel. q or the tray leaves.
--
-- The sky is drawn as well as the position: most time spent looking at
-- this is time before a fix, and a screen saying only "no fix" cannot
-- tell you to move the board.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")

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
local OK, WARM, COLD = 0x60c060, 0xc0a020, 0x405060

local FW, FH = 6, 12
local ROWH = FH + 4

-- ---- drawing ----

-- Padded to the width it is given, so a line erases what it replaces.
-- The window is not cleared between frames: a full repaint once a
-- second is what makes a panel flicker, since every rectangle is a
-- message and the whole window goes out to move one digit.
local function text(x, y, s, fg, bg, pad)
	s = tostring(s or "")
	if pad and #s < pad then
		s = s .. string.rep(" ", pad - #s)
	end
	if s == "" then
		return
	end

	local room = (W - x) // FW

	if room < 1 then
		return
	end
	if #s > room then
		s = s:sub(1, room)
	end

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- one satellite, as a column whose height is its signal. 50 dB is a
-- strong reading and nothing sensible exceeds it, so that is the top.
local function bar(x, y, h, snr)
	local n = math.min(snr or 0, 50)
	local up = (n * h) // 50
	local color = n >= 35 and OK or (n > 0 and WARM or COLD)

	fb.fill({ x = x, y = y, w = 5, h = h }, BG, false)
	if up > 0 then
		fb.fill({ x = x, y = y + h - up, w = 5, h = up }, color,
		    false)
	end
end

-- hh:mm:ss out of seconds into the day, which is what a sentence
-- carries: there is no timezone in NMEA and none is invented here.
local function hms(t)
	if not t then
		return "--:--:--"
	end
	return ("%02d:%02d:%02d UTC"):format(t // 3600, (t % 3600) // 60,
	    math.floor(t % 60))
end

local function ymd(d)
	if not d then
		return "-------/--"
	end
	return ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
end

-- fixed rows, so every frame writes the same lines at the same places
-- and nothing has to be erased first
local COLS = (W - 4) // FW
local ROW = {}

for i = 0, 5 do
	ROW[i] = 2 + i * ROWH
end

local BARTOP = ROW[5] + ROWH + 2
local BARH = H - BARTOP - FH - 6

local function draw(f, st)
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

	text(2, ROW[4], ("%s  %s"):format(ymd(f and f.date),
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

	-- strongest first, so the ones that matter are at the left and a
	-- window too narrow for the whole sky drops the silent ones.
	table.sort(sky, function(a, b)
		return (a.snr or 0) > (b.snr or 0)
	end)

	if BARH > 8 then
		local x, i = 2, 1

		while x + 5 < W - 2 do
			bar(x, BARTOP, BARH, sky[i] and sky[i].snr)
			x = x + 7
			i = i + 1
		end
	end

	if st then
		text(2, H - FH - 2, ("%s baud  %d ok  %d bad"):format(
		    tostring(st.baud), st.good or 0, st.bad or 0), DIM, BG,
		    COLS)
	end
end

-- ---- asking ----

local function ask(op)
	local rp, send = thread.replyport()

	sys.send(gps, { op = op, reply = { __right = send } })
	return thread.recvtimeout(rp, 2000)
end

-- ---- the loop ----

local ev = prog.events()
local EVERY_MS = 1000
local running = true

-- Two threads rather than one alt over both: a repaint is on a clock
-- and a keystroke is not, and the receiver answers a question that
-- takes a round trip. One waiting on either would hold the other up.
-- the one full clear: everything after it writes over its own row
fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)

thread.spawn(function()
	while running do
		draw(ask("fix"), ask("stats"))
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
