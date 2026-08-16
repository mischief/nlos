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

-- the rows, rebuilt on each paint: what is being shown is a machine
-- that moves, and a cached line is a line that goes stale on the glass.
local function lines()
	local s = sys.stats()
	local out = {}

	local function row(label, value, color)
		out[#out + 1] = { label = label, value = value,
		    color = color }
	end

	local function head(name)
		out[#out + 1] = { head = name }
	end

	head("machine")
	row("version", _VERSION .. " on " .. tostring(s.arch))
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
	row("in use", kb(s.lua_live) .. " by " .. tostring(s.procs) ..
	    " procs")
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
			row("wifi", state == "joined" and
			    (state .. " " .. ssid) or state,
			    state == "joined" and FG or WARN)
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

-- ---- drawing ----

local rows = {}
local off = 0
local visible = true

-- what is on the glass, by screen position, so a repaint can send only
-- the rows that changed.
--
-- Everything here moves once a second, and a full window is a fill plus
-- a message per line: painting all of it to move one number is what
-- makes a panel flicker. Most rows are the same second to second.
local shown = {}

local function rowat(i)
	return MARGIN + (i - off - 1) * ROWH
end

local function paintrow(i)
	local r = rows[i]
	local y = rowat(i)

	fb.fill({ x = 0, y = y, w = W, h = ROWH }, BG, true)
	if r.head then
		text(MARGIN, y, r.head, HEAD)
		fb.fill({ x = MARGIN, y = y + ROWH - 2,
		    w = W - MARGIN * 2, h = 1 }, DIM)
	else
		text(MARGIN, y, r.label, DIM)
		text(MARGIN + 9 * FW, y, r.value, r.color or FG)
	end
end

-- what a row looks like, as one string: the test for "has this
-- changed" has to cover everything painted, colour included.
local function rowkey(r)
	if r.head then
		return "h\0" .. r.head
	end
	return "r\0" .. r.label .. "\0" .. r.value .. "\0" ..
	    tostring(r.color)
end

local function draw(all)
	if not visible then
		return
	end
	if all then
		fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)
		shown = {}
	end

	local seen = {}

	for i = off + 1, #rows do
		if rowat(i) + ROWH > H then
			break
		end
		local k = rowkey(rows[i])

		seen[i] = k
		if shown[i] ~= k then
			paintrow(i)
		end
	end

	-- a row that scrolled off or vanished leaves its pixels behind,
	-- so what is no longer listed is cleared rather than forgotten.
	for i in pairs(shown) do
		if not seen[i] then
			local y = rowat(i)

			if y >= 0 and y + ROWH <= H then
				fb.fill({ x = 0, y = y, w = W, h = ROWH },
				    BG, true)
			end
		end
	end
	shown = seen
end

local function refresh()
	rows = lines()
	draw(false)
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
-- running the list off the top into blank glass.
local function scroll(by)
	local fits = (H - MARGIN) // ROWH
	local most = #rows - fits
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
		while true do
			local _, _, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-1)
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(1)
			end
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
	rows = lines()
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
				rows = lines()
				draw(true)
			end
		elseif m == "q" then
			return
		end
		refresh()
	end
end)

thread.run()
