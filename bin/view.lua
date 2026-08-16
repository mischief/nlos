-- view: read a file on the panel.
--
--	> view /sd/notes.txt
--
--	the trackball or a drag scrolls; q leaves.

-- What dio opens a text file with. It takes the path as an ordinary
-- argument, so nothing here knows whether a person typed it or the
-- launcher was asked to open it -- which is the whole point of dio
-- carrying the path in argv rather than inventing a protocol.

-- Text is utf8 and is not sanitised: los.font draws a codepoint it has
-- no glyph for as a blank cell, so a binary opened here shows its shape
-- rather than being refused, and nothing has to guess what is text.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local frame = require("frame")
local font = require("los.font")

local N = prog.ns()
local fb = prog.screen()
local path = arg[1]

if not fb then
	io.stderr:write("view: no framebuffer on this machine\n")
	os.exit(1)
end
if not path then
	io.stderr:write("usage: view FILE\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local HEAD = 0x7fdbff

local FW, FH = 6, 12
local ROWH = FH + 1
local MARGIN = 2
local COLS = (W - MARGIN * 2) // FW
local TOP = ROWH + 3

local function text(x, y, s, fg)
	if s == "" then
		return
	end

	local px, w, h = font.render(s, fg or FG, BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- ---- the file ----

local body, err = N and N:readfile(path)

-- tabs first: the renderer draws one cell per codepoint, so a tab is a
-- glyph rather than a stop and a source file comes out ragged.
if body then
	body = body:gsub("\t", "    ")
else
	body = "cannot read: " .. tostring(err)
end

-- lib/frame.lua holds the wrapping, the scroll and where a point lands.
-- Folded rather than clipped: a long line is content, and a reader that
-- hides it is worse than one that wraps it.
local F = frame.new(COLS, (H - TOP) // ROWH)

F:settext(body)

-- ---- drawing ----

local visible = true
local shown = {}

local function rows()
	return F.rows
end

local function draw(all)
	if not visible then
		return
	end
	if all then
		fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)
		shown = {}
		-- the name stays put while the body scrolls under it: on a
		-- screen this size, what is being read is a question asked
		-- often and answered by nothing else on the glass.
		text(MARGIN, 1, path:sub(-COLS), HEAD)
		fb.fill({ x = 0, y = ROWH + 1, w = W, h = 1 }, DIM)
	end

	local seen = {}

	for i = 1, rows() do
		local l = F:line(i) or ""
		local y = TOP + (i - 1) * ROWH

		seen[i] = l
		if shown[i] ~= l then
			fb.fill({ x = 0, y = y, w = W, h = ROWH }, BG, true)
			text(MARGIN, y, l)
		end
	end
	shown = seen
end

local function scroll(by)
	if F:scroll(by) then
		draw(false)
	end
end

-- ---- input ----

local ev = prog.events()

if not ev then
	io.stderr:write("view: not running under the panel\n")
	os.exit(1)
end

local point = prog.mouse()

if point then
	thread.spawn(function()
		while true do
			local _, _, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-rows() // 2)
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(rows() // 2)
			end
		end
	end)
end

thread.spawn(function()
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
