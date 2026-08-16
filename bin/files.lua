-- files: the namespace, on the panel.
--
--	> files [DIR]
--
--	tap a directory to enter it, ".." to go up, a file to open it.
--	the trackball scrolls; q leaves.

-- Opening is not starting. This asks dio to open a path and dio's
-- rules decide what runs -- so this program names no program, holds no
-- right to start one, and cannot be talked into launching something a
-- rule does not already allow. See task/dio.lua on the open port.

-- No capability: what it lists is the namespace it was given, which is
-- also the whole of what it can reach. A session mounted narrower sees
-- less, with nothing here to say about it.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local ns = require("ns")

local N = prog.ns()
local fb = prog.screen()

if not fb then
	io.stderr:write("files: no framebuffer on this machine\n")
	os.exit(1)
end
if not N then
	io.stderr:write("files: no namespace\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local HEAD, DIRC = 0x7fdbff, 0xffdc00

local FW, FH = 6, 12
local ROWH = FH + 4
local MARGIN = 4
local TOP = FH + 5

local function text(x, y, s, fg)
	s = tostring(s or "")
	if s == "" then
		return
	end

	local room = (W - x) // FW

	if #s > room then
		s = s:sub(1, room)
	end

	local px, w, h = font.render(s, fg or FG, BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- ---- where we are ----

local here = arg[1] or "/"
local ents = {}
local off = 0
local visible = true
local shown = {}

local function rows()
	return (H - TOP) // ROWH
end

local function size(n)
	if not n or n == 0 then
		return ""
	end
	if n < 1024 then
		return tostring(n)
	end
	return string.format("%dK", n // 1024)
end

local function listdir()
	local e, lerr = N:readdir(here)

	ents = {}
	-- ".." first and always, including at the root, where it is the
	-- one entry that does nothing: a list you can get stuck in is
	-- worse than a line that says so.
	if here ~= "/" then
		ents[1] = { name = "..", dir = true, up = true }
	end
	if not e then
		ents[#ents + 1] = { name = tostring(lerr), err = true }
		return
	end
	for _, x in ipairs(e) do
		ents[#ents + 1] = x
	end
	off = 0
end

-- ---- drawing ----

local function draw(all)
	if not visible then
		return
	end
	if all then
		fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)
		shown = {}
		text(MARGIN, 1, here, HEAD)
		fb.fill({ x = 0, y = FH + 3, w = W, h = 1 }, DIM)
	end

	local seen = {}

	for i = 1, rows() do
		local e = ents[off + i]
		local y = TOP + (i - 1) * ROWH
		local k = e and (e.name .. "\0" .. tostring(e.dir) .. "\0" ..
		    tostring(e.size)) or ""

		seen[i] = k
		if shown[i] ~= k then
			fb.fill({ x = 0, y = y, w = W, h = ROWH }, BG, true)
			if e then
				local c = e.err and DIM or
				    (e.dir and DIRC or FG)

				text(MARGIN, y + 2,
				    e.name .. (e.dir and "/" or ""), c)
				if not e.dir then
					text(W - MARGIN - 5 * FW, y + 2,
					    size(e.size), DIM)
				end
			end
		end
	end
	shown = seen
end

local function scroll(by)
	local most = #ents - rows()
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
		draw(false)
	end
end

-- ---- opening ----

local ev = prog.events()

if not ev then
	io.stderr:write("files: not running under the panel\n")
	os.exit(1)
end

-- the door dio gave us, where /etc/dio.lua says this entry opens
-- things. Absent when it does not, and then a tap on a file says so
-- rather than doing nothing.
local door = prog.ctx and prog.ctx.open and prog.ctx.open.__right
local note = nil

local function open(e)
	local path = ns.clean(here .. "/" .. e.name)

	if e.dir or e.up then
		here = e.up and (here:match("^(.*)/[^/]+$") or "/") or path
		if here == "" then
			here = "/"
		end
		listdir()
		draw(true)
		return
	end
	if not door then
		note = "no way to open things from here"
		draw(true)
		return
	end
	sys.send(door, { op = "open", path = path, type = "text",
	    src = "files" })
end

local function tapped(y)
	local i = (y - TOP) // ROWH + 1

	if y < TOP or i < 1 or i > rows() then
		return
	end

	local e = ents[off + i]

	if e and not e.err then
		open(e)
	end
end

local point = prog.mouse()

if point then
	thread.spawn(function()
		local down = false

		while true do
			local _, y, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-1)
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(1)
			else
				local pressed = (b & 1) ~= 0

				-- the press edge: a finger held on a row
				-- must open it once.
				if pressed and not down then
					tapped(y)
				end
				down = pressed
			end
		end
	end)
end

thread.spawn(function()
	listdir()
	draw(true)

	while true do
		local m = thread.recv(ev)

		if sys.hungup(ev) then
			return
		end
		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				draw(true)
			end
		elseif m == "q" then
			return
		end
	end
end)

thread.run()
