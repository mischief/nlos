-- settings: what the machine is and what it is doing, on the panel.
--
--	the trackball scrolls; q leaves where there is a keyboard.

-- Everything here is read. sys.stats and sys.meminfo are observations
-- rather than authority, and the radio and the lease are files in the
-- namespace this was given -- so it holds no capability, and a session
-- without those mounts shows fewer lines rather than failing.

-- TODO: a reboot button wants the power right, which dio grants the
-- terminal and not an ordinary app. /etc/dio.lua would have to say per
-- entry what an app is handed -- the `caps` list etc/services.lua
-- already has.

-- TODO: a brightness slider wants the backlight driven as a timer
-- rather than a pin. It is one gpio level today, so there is nothing
-- between off and on to offer.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local battery = require("battery").meter()
local audio = require("audio")

local N = prog.ns()
local fb = prog.screen()

if not fb then
	io.stderr:write("settings: no framebuffer on this machine\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

-- the panel's own colors, matching bin/wifiui.lua: this runs on a
-- handheld, often at night.
local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local HEAD, WARN = 0x7fdbff, 0xc06060

local FW, FH = 6, 12		-- los.font's cell
local ROWH = FH + 2
local MARGIN = 4

-- two pages: what the machine is, and what it may be told. The bar is
-- tall enough to hit with a finger rather than a cursor.
local TABH = FH + 8
local TOP = TABH + MARGIN
local view = "status"

-- room is in pixels from x, so a column can say where it ends. Without
-- one the window's own edge is the limit.
local function text(x, y, s, fg, bg, room)
	s = tostring(s or "")
	if s == "" then
		return
	end

	room = ((room or (W - x))) // FW

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

-- ---- what there is to say ----

local function readfile(path)
	return N and N:readfile(path) or nil
end

local function kb(n)
	return string.format("%dK", (n or 0) // 1024)
end

-- how long, in the units a person reads: seconds under a minute, then
-- minutes, then hours -- one unit is enough to know whether a machine
-- has just come up.
local function since(ms)
	local s = (ms or 0) // 1000

	if s < 60 then
		return s .. "s"
	end
	if s < 3600 then
		return string.format("%dm %ds", s // 60, s % 60)
	end
	return string.format("%dh %dm", s // 3600, (s % 3600) // 60)
end

-- the lease, one value per file, as task/dhcpd.lua serves it
local function net(name)
	local v = readfile("/net/" .. name)

	return v and v:gsub("%s+$", "") or nil
end

local function wifi()
	local txt = readfile("/net/wifi/status")

	if not txt then
		return nil
	end
	return txt:match("state (%S+)") or "unknown",
	    txt:match("ssid ([^\n]*)") or ""
end

-- the sections, rebuilt on each paint: what is being shown is a machine
-- that moves, and a cached line is a line that goes stale on the glass.
--
-- Sections rather than one list, because the layout below flows them
-- into however many columns the window has room for and a section is
-- what must not be split across two.
local function sections()
	local s = sys.stats()
	local out = {}
	local cur

	local function row(label, value, color)
		cur[#cur + 1] = { label = label, value = value,
		    color = color }
	end

	local function head(name)
		cur = {}
		out[#out + 1] = { name = name, rows = cur }
	end

	-- the battery first: it is the one figure a handheld is picked up
	-- to check, and it is absent on a machine with a wall socket.
	local mv, pct, chg = battery()

	if mv then
		head("battery")
		-- no bar and no figure on the charger: the pin reads the
		-- charger's node there, not the cell, so there is nothing
		-- honest to draw.
		if pct then
			cur[#cur + 1] = { bar = pct }
			row("charge", string.format("%d%%  %.2fV", pct,
			    mv / 1000))
		else
			row("charge", "unknown", DIM)
		end
		row("source", chg and "usb" or "pack", chg and HEAD or FG)
	end

	head("machine")
	-- one fact per row: a column is narrow, and a row that says two
	-- things is the row that loses its tail off the edge.
	row("version", _VERSION)
	row("arch", tostring(s.arch))
	row("uptime", since(sys.uptime_ms()))
	row("cpus", tostring(s.cpus or 1))

	head("memory")
	-- one figure for what is left, which is the question being asked.
	--
	-- From the chunk pool where the machine has one: on a board with
	-- PSRAM the heaps are there and everything else is in internal
	-- sram, so that pool is what bounds how many procs there can be.
	-- Elsewhere the two are the same memory and this is that.
	local pooled = (s.chunktotal or 0) > 0
	local free = pooled and s.chunkavail or s.memavail
	local total = pooled and s.chunktotal or s.memtotal

	row("free", kb(free) .. " of " .. kb(total))
	-- live, not mapped: what the procs are holding, rather than what
	-- the heap has taken from the pool to serve them. lib/ps.lua
	-- reports both, and reporting both here is what made this read
	-- as a puzzle instead of an answer.
	row("in use", kb(s.lua_live))
	row("procs", tostring(s.procs))
	if (s.broke or 0) > 0 then
		row("broke", tostring(s.broke), WARN)
	end

	-- the biggest few, since "what is holding it" is the question a
	-- memory figure raises and the answer is a short list.
	local procs = {}

	for _, pid in ipairs(sys.procs()) do
		local used = sys.meminfo(pid)

		if used then
			procs[#procs + 1] = { pid = pid, used = used,
			    name = sys.name(pid) or "?" }
		end
	end
	table.sort(procs, function(a, b) return a.used > b.used end)
	-- with the pid, because two procs may wear one name: an entry in
	-- the launcher may be started more than once, and "which of the
	-- three" is exactly what the row is being read to answer.
	for i = 1, math.min(3, #procs) do
		row(i == 1 and "biggest" or "",
		    ("%s(%d) %s"):format(procs[i].name, procs[i].pid,
		    kb(procs[i].used)))
	end

	local state, ssid = wifi()
	local addr = net("addr")

	if state or addr then
		head("network")
		if state then
			row("wifi", state, state == "joined" and FG or WARN)
			-- the name on its own row: an ssid is as long as
			-- whoever named it felt like making it.
			if state == "joined" and ssid ~= "" then
				row("ssid", ssid)
			end
		end
		if addr then
			row("address", addr)
		end
		local gw = net("gw")

		if gw then
			row("gateway", gw)
		end
	end

	head("power")
	row("reboot", "not here yet", DIM)

	return out
end

-- ---- layout ----

-- as many columns as the window has room for. A column is a label field
-- and enough after it for the values above; two of them is what fills a
-- 320-wide panel, and one is what a narrow window falls back to.
local COLGAP = 8
local MINCOL = 20 * FW
local NCOL = math.max(1, (W - MARGIN) // (MINCOL + COLGAP))
local COLW = (W - MARGIN - (NCOL - 1) * COLGAP) // NCOL

-- the label field is as wide as the widest label plus a space, rather
-- than a fixed guess: every character it does not spend is one the
-- value gets, and a value that runs off the edge is what a fixed field
-- costs. Set by place() below, since it depends on what is being shown.
local LABELW = 8 * FW

-- how many rows land on the glass, which is what a section is flowed
-- against and where a scroll stops.
local PAGE = (H - TOP) // ROWH

local function colx(c)
	return MARGIN + (c - 1) * (COLW + COLGAP)
end

-- flow the sections into the columns, top to bottom and then across.
-- A section is kept whole: it moves to the next column rather than
-- being split, since a heading in one column over its rows in another
-- says something untrue. The last column takes whatever is left over
-- and scrolls, which only a very small window reaches.
local function place(secs)
	local out = {}
	local col, at = 1, 0
	local widest = 0

	for _, sec in ipairs(secs) do
		for _, r in ipairs(sec.rows) do
			if r.label and #r.label > widest then
				widest = #r.label
			end
		end
	end
	LABELW = (widest + 1) * FW

	for _, sec in ipairs(secs) do
		local need = 1 + #sec.rows

		if at > 0 and at + need > PAGE and col < NCOL then
			col = col + 1
			at = 0
		end
		at = at + 1
		out[#out + 1] = { col = col, at = at, head = sec.name }
		for _, r in ipairs(sec.rows) do
			at = at + 1
			r.col, r.at = col, at
			out[#out + 1] = r
		end
		at = at + 1	-- a blank line between sections
	end
	return out
end

-- ---- drawing ----

local items = {}
local off = 0
local visible = true

-- what is on the glass, by screen position, so a repaint can send only
-- the rows that changed.
--
-- Everything here moves once a second, and a full window is a fill plus
-- a message per line: painting all of it to move one number is what
-- makes a panel flicker. Most rows are the same second to second.
local shown = {}

local function rowat(r)
	return TOP + (r.at - off - 1) * ROWH
end

-- the gauge: a filled proportion of the column, since a bar answers
-- "how much is left" at a glance and three digits do not. Red when
-- there is little enough left to act on.
local BARH = 6
local FULL, LOW = 0x60c060, 0xc06060

local function paintbar(r, x, y)
	local w = COLW - LABELW // 2
	local fill = w * math.min(r.bar, 100) // 100

	fb.fill({ x = x, y = y + (ROWH - BARH) // 2, w = w, h = BARH }, DIM)
	if fill > 0 then
		fb.fill({ x = x, y = y + (ROWH - BARH) // 2, w = fill,
		    h = BARH }, r.bar <= 15 and LOW or FULL)
	end
end

local function paint(r)
	local x = colx(r.col)
	local y = rowat(r)

	fb.fill({ x = x, y = y, w = COLW, h = ROWH }, BG, true)
	if r.head then
		text(x, y, r.head, HEAD, nil, COLW)
		fb.fill({ x = x, y = y + ROWH - 2, w = COLW, h = 1 }, DIM)
	elseif r.bar then
		paintbar(r, x, y)
	else
		text(x, y, r.label, DIM, nil, LABELW)
		text(x + LABELW, y, r.value, r.color or FG, nil,
		    COLW - LABELW)
	end
end

-- what a row looks like, as one string: the test for "has this
-- changed" has to cover everything painted, colour included.
local function rowkey(r)
	if r.head then
		return "h\0" .. r.head
	end
	if r.bar then
		return "b\0" .. r.bar
	end
	return "r\0" .. r.label .. "\0" .. r.value .. "\0" ..
	    tostring(r.color)
end

local function slot(r)
	return r.col .. "\0" .. r.at
end

-- ---- what may be told ----
--
-- One row per option: a label, what it reads now, and what a tap makes
-- it next. An option the machine cannot honour is listed and says so
-- rather than being hidden, since absent is a fact worth seeing.
local options = {}

local function audiochoices()
	local out = { "auto" }

	for _, k in ipairs(audio.sinks()) do
		out[#out + 1] = k
	end
	return out
end

options[1] = {
	label = "audio",
	read = function()
		local now = audio.sink()
		local where = sys.usbconsole and sys.usbconsole() and
		    " (usb takes the console)" or ""

		return now .. where
	end,
	next = function()
		local c = audiochoices()
		local now = audio.sink()

		for i, k in ipairs(c) do
			if k == now then
				return c[i % #c + 1]
			end
		end
		return c[1]
	end,
	set = audio.setsink,
}

-- in fifths: a tap cycles, so eleven stops would be a long way round
-- to turn it down.
local VOLSTEP = 20

options[2] = {
	label = "volume",
	read = function()
		return audio.volume() .. "%"
	end,
	next = function()
		return (audio.volume() + VOLSTEP) % (100 + VOLSTEP)
	end,
	set = audio.setvolume,
}

local optnote = nil

local function drawopts()
	fb.fill({ x = 0, y = TOP, w = W, h = H - TOP }, BG, true)

	for i, o in ipairs(options) do
		local y = TOP + (i - 1) * (ROWH + 8)

		if y + ROWH > H then
			break
		end
		text(MARGIN, y, o.label, DIM, nil, LABELW)
		text(MARGIN + LABELW, y, o.read(), FG, nil, W - LABELW - MARGIN)
		fb.fill({ x = 0, y = y + ROWH + 3, w = W, h = 1 }, 0x1c1c24)
	end

	if optnote then
		text(MARGIN, H - ROWH, optnote, WARN, nil, W - MARGIN)
	end
end

local function optat(y)
	local i = (y - TOP) // (ROWH + 8) + 1

	return options[i]
end

local function draw(all)
	if not visible then
		return
	end
	if all then
		fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)
		shown = {}
	end
	if all then
		local half = W // 2

		for i, t in ipairs({ "STATUS", "OPTIONS" }) do
			local x = (i - 1) * half
			local on = view == t:lower()

			fb.fill({ x = x, y = 0, w = half, h = TABH - 1 },
			    on and 0x243044 or BG, true)
			text(x + (half - #t * FW) // 2, (TABH - FH) // 2, t,
			    on and HEAD or DIM, on and 0x243044 or BG, half)
		end
		fb.fill({ x = 0, y = TABH - 1, w = W, h = 1 }, DIM)
	end

	if view == "options" then
		drawopts()
		return
	end

	local seen = {}

	for _, r in ipairs(items) do
		local y = rowat(r)

		if y >= 0 and y + ROWH <= H then
			local k = slot(r)

			seen[k] = rowkey(r)
			if shown[k] ~= seen[k] then
				paint(r)
			end
		end
	end

	-- a row that scrolled off or vanished leaves its pixels behind,
	-- so what is no longer listed is cleared rather than forgotten.
	for k in pairs(shown) do
		if not seen[k] then
			local c, at = k:match("^(%d+)\0(%d+)$")
			local y = TOP + (tonumber(at) - off - 1) * ROWH

			if y >= 0 and y + ROWH <= H then
				fb.fill({ x = colx(tonumber(c)), y = y,
				    w = COLW, h = ROWH }, BG, true)
			end
		end
	end
	shown = seen
end

-- a wider label moves every value, so what is on the glass is no longer
-- where the diff believes it is: that repaints the window rather than
-- the rows that changed.
-- the options page holds still: nothing on it changes unless a finger
-- changes it, so the timer leaves it alone rather than repainting it
-- once a second.
local function refresh()
	local was = LABELW

	if view == "options" then
		return
	end
	items = place(sections())
	draw(LABELW ~= was)
end

-- ---- input ----

-- the window and any keys arrive here; the pointer is a port of its
-- own, read below. Without an event port this is not running on a
-- panel: bin/stats.lua is the same figures for a terminal, and saying
-- so beats drawing over whatever owns the screen.
local ev = prog.events()

if not ev then
	io.stderr:write("settings: not running under the panel; " ..
	    "try stats\n")
	os.exit(1)
end

-- the furthest this scrolls: the offset at which the last row still
-- lands on the screen, so a roll stops with the end in view rather than
-- running the list off the top into blank glass. Measured against the
-- deepest column, which the flow above fills last.
local function scroll(by)
	local deepest = 0

	for _, r in ipairs(items) do
		if r.at > deepest then
			deepest = r.at
		end
	end

	local most = deepest - PAGE
	local to = off + by

	if most < 0 then
		most = 0
	end
	if to < 0 then
		to = 0
	elseif to > most then
		to = most
	end
	if to ~= off then
		off = to
		-- the whole window: every row moved, so nothing that is
		-- on the glass is where the diff thinks it is.
		draw(true)
		return true
	end
	return false
end

-- the pointer is a port of its own, and a thread of its own reads it:
-- the loop below has to end when dio does, and a read that returns
-- nothing is how that arrives.
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
			elseif (b & 1) ~= 0 and not down then
				if y < TABH then
					view = x < W // 2 and "status" or
					    "options"
					optnote = nil
					draw(true)
				elseif view == "options" then
					local o = optat(y)

					if o then
						local ok, why = o.set(o.next())

						-- not `ok and nil or why`:
						-- nil is false, so that
						-- reports "nil" on success
						optnote = nil
						if not ok then
							optnote = tostring(why)
						end
						draw(true)
					end
				end
			end
			down = (b & 1) ~= 0
		end
	end)
end

-- a repaint on a timer, because everything here moves: memory, uptime
-- and the radio all change while this is on the glass, and a panel
-- showing what was true when it started is worse than showing nothing.
--
-- recvtimeout rather than await: nothing arrives on an idle panel, so a
-- plain receive would hold the last figures until a finger touched it.
thread.spawn(function()
	items = place(sections())
	draw(true)

	while true do
		local m = thread.recvtimeout(ev, 1000)

		if sys.hungup(ev) then
			return
		end

		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				-- dio keeps no pixels for an app that was
				-- not in front, so coming back is a fresh
				-- window rather than the one left behind.
				items = place(sections())
				draw(true)
			end
		elseif m == "q" then
			return
		end
		refresh()
	end
end)

thread.run()
