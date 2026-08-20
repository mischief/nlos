-- amp: a playlist and a player, for a panel you touch.
--
--	> amp [DIR]
--
--	BROWSE lists files and + adds one; LIST is the playlist, where -
--	drops a track and a tap on the name plays it. q leaves.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local ns = require("ns")
local wav = require("wav")
local adpcm = require("adpcm")
local usb = require("usb")
local uac = require("uac")

local N = prog.ns()
local fb = prog.screen()

if not fb then
	io.stderr:write("amp: no framebuffer on this machine\n")
	os.exit(1)
end
if not N then
	io.stderr:write("amp: no namespace\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

-- the colours everybody recognises: black glass, green readout, and a
-- title bar that is not either.
local BG = 0x101014
local FG = 0xd0d0d8
local DIM = 0x6a6a76
local GREEN = 0x3cff5a
local BAR = 0x2a2a3a
local SEL = 0x243044
local HOT = 0x7fdbff

local FW, FH = font.size()

if not FW or FW == 0 then
	FW, FH = 6, 12
end

-- a finger is not a mouse: rows and buttons are sized to be hit, not
-- to be dense. The button column is square so it reads as a button.
local ROWH = FH + 10
local BTNW = ROWH
local MARGIN = 4
local HEADH = FH + 10
local TABH = FH + 10
local TOP = HEADH + TABH + 2

local function rows()
	return (H - TOP) // ROWH
end

-- ---- drawing ----

local function fill(x, y, w, h, c)
	if w > 0 and h > 0 then
		fb.fill({ x = x, y = y, w = w, h = h }, c, true)
	end
end

local function text(x, y, s, fg, bg)
	s = tostring(s or "")
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

-- a labelled box, which is every control here
local function button(x, y, w, h, label, fg, bg)
	fill(x, y, w, h, bg or BAR)
	fill(x, y, w, 1, DIM)
	fill(x, y + h - 1, w, 1, 0x000000)
	text(x + (w - #label * FW) // 2, y + (h - FH) // 2, label, fg or FG,
	    bg or BAR)
end

-- ---- state ----

local here = arg[1] or "/"
local ents = {}
local view = "browse"
local off, ploff = 0, 0
local pl = {}
local cur = nil		-- index into pl of what is loaded
local playing = false
local elapsed, total = 0, 0
local note = nil
local visible = true

local function base(p)
	return (tostring(p or ""):gsub(".*/", ""))
end

local function mmss(s)
	s = math.floor(s or 0)
	return string.format("%d:%02d", s // 60, s % 60)
end

-- ---- the disk ----

local function playable(name)
	return name:lower():match("%.wav$") ~= nil
end

local function listdir()
	local e, lerr = N:readdir(here)

	ents = {}
	if here ~= "/" then
		ents[1] = { name = "..", dir = true, up = true }
	end
	if not e then
		ents[#ents + 1] = { name = tostring(lerr), err = true }
		return
	end
	for _, x in ipairs(e) do
		if x.dir or playable(x.name) then
			ents[#ents + 1] = x
		end
	end
	off = 0
end

-- how long a track runs, from its header alone: a playlist that says
-- nothing about length is a list of names, not of music.
local function seconds(path)
	local f = N:open(path, "r")

	if not f then
		return nil
	end

	local head = f:read(4096)

	f:close()
	if not head then
		return nil
	end

	local w = wav.header(head)

	return w and wav.seconds(w) or nil
end

-- ---- the player ----
--
-- One thread owns the device: it opens the stream, feeds it, and stops.
-- The ui thread only ever sets `want`, so a tap never waits on the
-- disk and the two never touch the same handle.
local want = nil	-- {index} to start, "stop", or nil
local devready = nil

local function device()
	if devready ~= nil then
		return devready
	end
	devready = false
	if not sys.usbhost then
		return false
	end
	if not sys.usbhost() then
		return false
	end

	local desc

	for _ = 1, 30 do
		desc = sys.usbdesc()
		if desc then
			break
		end
		thread.sleep(100)
	end
	devready = desc ~= nil and usb.parse(desc) or false
	return devready
end

-- feed one track until it ends or something else is wanted
local function run(path)
	local cfg = device()

	if not cfg then
		note = "no audio device"
		return
	end

	local f = N:open(path, "r")

	if not f then
		note = "cannot open " .. base(path)
		return
	end

	local head = f:read(4096)
	local w = head and wav.header(head)

	if not w then
		f:close()
		note = base(path) .. ": not a wav"
		return
	end

	local stream = uac.playback(cfg, { rate = w.rate,
	    channels = w.channels, width = w.width })
	local packet = stream and uac.packet(stream, w.rate)

	if not packet then
		f:close()
		note = "this device will not take that track"
		return
	end
	if not sys.usbplay(stream.interface, stream.alt,
	    stream.endpoint.address, packet, w.rate) then
		f:close()
		note = "the device refused to play"
		return
	end

	total = wav.seconds(w)
	elapsed = 0
	f:seek("set", w.at - 1)

	local step = 32768

	if w.adpcm then
		step = (step // w.block) * w.block
		if step < w.block then
			step = w.block
		end
	end

	local left, pending, carry = w.bytes, "", ""
	local fed = 0

	while (left > 0 or #pending > 0) and want == nil do
		if #pending == 0 then
			local raw = f:read(left < step and left or step) or ""

			if raw == "" then
				break
			end
			left = left - #raw
			if w.adpcm then
				raw = carry .. raw

				local out, o = {}, 1

				while o + w.block - 1 <= #raw do
					out[#out + 1] = adpcm.block(raw, o,
					    w.channels, w.block)
					o = o + w.block
				end
				carry = raw:sub(o)
				pending = table.concat(out)
			else
				pending = raw
			end
		end

		local took = sys.usbwrite(pending)

		if not took then
			break
		end
		pending = pending:sub(took + 1)
		fed = fed + took
		elapsed = fed / (w.rate * w.channels * 2)
		if #pending > 0 then
			thread.sleep(10)
		end
	end

	thread.sleep(200)
	sys.usbstop()
	f:close()
end

-- ---- layout ----

local T = {}	-- transport buttons, filled by drawhead

local function drawhead()
	fill(0, 0, W, HEADH, BAR)

	local name = cur and pl[cur] and pl[cur].name or "amp"

	text(MARGIN, (HEADH - FH) // 2, name, playing and GREEN or FG, BAR)

	local clock = mmss(elapsed) .. " / " .. mmss(total)
	local bw = BTNW
	local x = W - bw * 4 - MARGIN

	text(x - #clock * FW - MARGIN, (HEADH - FH) // 2, clock, GREEN, BAR)

	T = {}
	for i, lab in ipairs({ "|<", playing and "||" or ">", "[]", ">|" }) do
		local bx = x + (i - 1) * bw

		button(bx, 1, bw - 1, HEADH - 2, lab, FG, BAR)
		T[i] = { x = bx, w = bw - 1 }
	end
end

local function drawtabs()
	local w = W // 2

	button(0, HEADH, w, TABH - 1,
	    "BROWSE", view == "browse" and HOT or DIM,
	    view == "browse" and SEL or BG)
	button(w, HEADH, W - w, TABH - 1,
	    "LIST " .. #pl, view == "list" and HOT or DIM,
	    view == "list" and SEL or BG)
	fill(0, HEADH + TABH - 1, W, 1, DIM)
end

local function drawrows()
	fill(0, TOP, W, H - TOP, BG)

	local n = rows()

	if view == "browse" then
		for i = 1, n do
			local e = ents[off + i]

			if not e then
				break
			end

			local y = TOP + (i - 1) * ROWH
			local c = e.err and 0xff6a6a or
			    (e.dir and HOT or FG)

			text(MARGIN, y + 5, e.name, c)
			if not e.dir and not e.err then
				button(W - BTNW, y, BTNW - 1, ROWH - 1, "+",
				    GREEN)
			end
			fill(0, y + ROWH - 1, W, 1, 0x1c1c24)
		end
	else
		for i = 1, n do
			local t = pl[ploff + i]

			if not t then
				break
			end

			local y = TOP + (i - 1) * ROWH
			local on = (ploff + i) == cur
			local bg = on and SEL or BG

			fill(0, y, W, ROWH - 1, bg)
			text(MARGIN, y + 5,
			    ("%d. %s"):format(ploff + i, t.name),
			    on and GREEN or FG, bg)

			local d = t.secs and mmss(t.secs) or ""

			text(W - BTNW - #d * FW - MARGIN, y + 5, d, DIM, bg)
			button(W - BTNW, y, BTNW - 1, ROWH - 1, "-", 0xff8a8a)
			fill(0, y + ROWH - 1, W, 1, 0x1c1c24)
		end
	end

	if note then
		fill(0, H - FH - 2, W, FH + 2, 0x301010)
		text(MARGIN, H - FH - 1, note, 0xff9a9a, 0x301010)
	end
end

local function draw()
	if not visible then
		return
	end
	drawhead()
	drawtabs()
	drawrows()
end

-- ---- what a tap means ----

local function add(e)
	local path = ns.clean(here .. "/" .. e.name)

	pl[#pl + 1] = { path = path, name = base(path), secs = seconds(path) }
	note = nil
end

local function enter(e)
	if e.up then
		here = here:match("^(.*)/[^/]+$") or "/"
		if here == "" then
			here = "/"
		end
	else
		here = ns.clean(here .. "/" .. e.name)
	end
	listdir()
end

local function transport(i)
	if i == 1 then
		if cur and cur > 1 then
			want = cur - 1
		end
	elseif i == 2 then
		if playing then
			want = "stop"
		elseif #pl > 0 then
			want = cur or 1
		end
	elseif i == 3 then
		want = "stop"
	elseif i == 4 then
		if cur and cur < #pl then
			want = cur + 1
		end
	end
end

local function tapped(x, y)
	note = nil
	if y < HEADH then
		for i, b in ipairs(T) do
			if x >= b.x and x < b.x + b.w then
				transport(i)
				return
			end
		end
		return
	end
	if y < HEADH + TABH then
		view = x < W // 2 and "browse" or "list"
		draw()
		return
	end

	local i = (y - TOP) // ROWH + 1

	if i < 1 or i > rows() then
		return
	end

	if view == "browse" then
		local e = ents[off + i]

		if not e or e.err then
			return
		end
		if e.dir or e.up then
			enter(e)
		elseif x >= W - BTNW then
			add(e)
		end
	else
		local at = ploff + i

		if not pl[at] then
			return
		end
		if x >= W - BTNW then
			table.remove(pl, at)
			if cur == at then
				want = "stop"
				cur = nil
			elseif cur and cur > at then
				cur = cur - 1
			end
		else
			want = at
		end
	end
	draw()
end

local function scroll(d)
	if view == "browse" then
		local n = #ents - rows()

		off = math.max(0, math.min(off + d, n > 0 and n or 0))
	else
		local n = #pl - rows()

		ploff = math.max(0, math.min(ploff + d, n > 0 and n or 0))
	end
	draw()
end

-- ---- threads ----

local ev = prog.ctx and prog.ctx.ev and prog.ctx.ev.__right or sys.SELF
local point = prog.mouse()

if point then
	thread.spawn(function()
		local down = false

		while true do
			local x, y, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-1)
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(1)
			else
				local pressed = (b & 1) ~= 0

				if pressed and not down then
					tapped(x, y)
				end
				down = pressed
			end
		end
	end)
end

-- the player: takes what the ui asked for and does it, one at a time
thread.spawn(function()
	while true do
		if want == nil then
			thread.sleep(50)
		elseif want == "stop" then
			want = nil
			playing = false
			elapsed = 0
			draw()
		else
			cur = want
			want = nil
			playing = true
			draw()

			local t = pl[cur]

			if t then
				run(t.path)
			end
			playing = false
			-- the next one, unless somebody said otherwise
			if want == nil and cur and pl[cur + 1] then
				want = cur + 1
			end
			draw()
		end
	end
end)

-- the clock, so the readout moves while a track plays
thread.spawn(function()
	while true do
		thread.sleep(500)
		if playing and visible then
			drawhead()
		end
	end
end)

thread.spawn(function()
	listdir()
	draw()

	while true do
		local m = thread.recv(ev)

		if sys.hungup(ev) then
			return
		end
		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				draw()
			end
		elseif m == "q" then
			want = "stop"
			return
		end
	end
end)

thread.run()
