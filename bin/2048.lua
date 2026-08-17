-- 2048: slide the tiles together.
--
--	> 2048
--
-- The trackball is the controller: its four directions are the four
-- moves. wasd and the arrows do the same, r starts over, escape leaves.

local prog = require("prog")
local memdraw = require("memdraw")
local mouse = require("mouse")
local slide = require("slide")
local font = require("los.font")
local sys = require("los.sys")
local thread = require("los.thread")

local fb = prog.screen()

if not fb then
	io.stderr:write("2048: no screen here\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = memdraw.bpp(mode.format) and mode.format or memdraw.BGRX
local FW, FH = font.size()

-- the game's own palette, which is the one everybody recognises.
local PAGE = 0xfaf8ef
local GRID = 0xbbada0
local EMPTY = 0xcdc1b4
local DARK = 0x776e65
local LIGHT = 0xf9f6f2
local PANEL = 0x3d3a33

-- tile colour and the ink that reads on it. Past 2048 the board keeps
-- the last colour rather than inventing more.
local TILE = {
	[2] = { 0xeee4da, DARK },
	[4] = { 0xede0c8, DARK },
	[8] = { 0xf2b179, LIGHT },
	[16] = { 0xf59563, LIGHT },
	[32] = { 0xf67c5f, LIGHT },
	[64] = { 0xf65e3b, LIGHT },
	[128] = { 0xedcf72, LIGHT },
	[256] = { 0xedcc61, LIGHT },
	[512] = { 0xedc850, LIGHT },
	[1024] = { 0xedc53f, LIGHT },
	[2048] = { 0xedc22e, LIGHT },
}

local function colors(v)
	return TILE[v] or (v > 2048 and TILE[2048]) or { EMPTY, DARK }
end

-- ---- where things sit ----

local N = 4
local TOP = FH + 8		-- the score line, and a rule under it
local GAP = 4

-- the largest square board that fits under the score line, centred in
-- what is left. A window is not always the panel: dio keeps a tray.
local CELL = math.min((W - GAP * (N + 1)) // N,
    (H - TOP - GAP * (N + 1)) // N)
local BOARD = CELL * N + GAP * (N + 1)
local BX = (W - BOARD) // 2
local BY = TOP + (H - TOP - BOARD) // 2

local function cellrect(x, y)
	return memdraw.rect(BX + GAP + (x - 1) * (CELL + GAP),
	    BY + GAP + (y - 1) * (CELL + GAP), CELL, CELL)
end

-- ---- drawing ----

local function fill(r, color)
	fb.fill(r, color)
end

local function text(x, y, s, fg, bg)
	s = tostring(s or "")
	if s == "" then
		return
	end

	local px, w, h = font.render(s, fg or DARK, bg or PAGE, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- centred in a cell, which is where a number belongs on a tile.
local function middle(r, s, fg, bg)
	local w = #tostring(s) * FW

	text(r.x + (r.w - w) // 2, r.y + (r.h - FH) // 2, s, fg, bg)
end

local B = slide.new({ n = N, rand = function(k)
	return math.random(k)
end })

local shown = {}		-- what is on the glass, to redraw only changes
local visible = true
local over = false

local function paintcell(x, y, force)
	local v = B:at(x, y)
	local i = (y - 1) * N + x

	if not force and shown[i] == v then
		return
	end
	shown[i] = v

	local r = cellrect(x, y)
	local c = colors(v)

	fill(r, v == 0 and EMPTY or c[1])
	if v ~= 0 then
		middle(r, v, c[2], c[1])
	end
end

local lastscore = -1

local function paintscore(force)
	if not force and lastscore == B.score then
		return
	end
	lastscore = B.score

	local s = ("score %d"):format(B.score)

	fill(memdraw.rect(0, 0, W, TOP), PANEL)
	text(4, 4, s, LIGHT, PANEL)

	local best = ("best %d"):format(B:best())

	text(W - 4 - #best * FW, 4, best, LIGHT, PANEL)
end

local function paint(force)
	if not visible then
		return
	end
	if force then
		fill(memdraw.rect(0, 0, W, H), PAGE)
		fill(memdraw.rect(BX, BY, BOARD, BOARD), GRID)
	end
	paintscore(force)
	for y = 1, N do
		for x = 1, N do
			paintcell(x, y, force)
		end
	end
	if over then
		local s = "no moves -- r starts over"

		text((W - #s * FW) // 2, BY + BOARD // 2 - FH // 2, s,
		    LIGHT, GRID)
	end
end

-- ---- playing ----

local function restart()
	B = slide.new({ n = N, rand = function(k)
		return math.random(k)
	end })
	over = false
	shown = {}
	lastscore = -1
	paint(true)
end

local function move(dir)
	if over then
		return
	end

	local moved = B:move(dir)

	if not moved then
		return
	end
	B:spawn()
	if not B:canmove() then
		over = true
	end
	paint(false)
	if over then
		paint(false)
	end
end

-- ---- what the ball and the keys mean ----

local WHEEL = {
	[mouse.WHEELUP] = "up",
	[mouse.WHEELDOWN] = "down",
	[mouse.WHEELLEFT] = "left",
	[mouse.WHEELRIGHT] = "right",
}

-- One detent of the ball is several clicks, which is what a list wants
-- and a board does not: a nudge would slide three times. A move is
-- taken at most this often, so a flick is one move and a held roll
-- repeats at a rate a player can follow.
local REPEAT = 180
local lastroll = -REPEAT

local function rolled(dir)
	local now = sys.uptime_ms()

	if now - lastroll < REPEAT then
		return
	end
	lastroll = now
	move(dir)
end

local KEY = {
	w = "up", a = "left", s = "down", d = "right",
	k = "up", h = "left", j = "down", l = "right",
	["\27[A"] = "up", ["\27[B"] = "down",
	["\27[C"] = "right", ["\27[D"] = "left",
}

local running = true

-- a record or a keystroke, told apart by parsing: they arrive on one
-- port and a mouse record is a string like any other.
local function event(m)
	if type(m) == "table" then
		if m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				shown = {}
				lastscore = -1
				paint(true)
			end
		end
		return
	end
	if type(m) ~= "string" then
		return
	end

	local _, _, b = mouse.parse(m)

	if b then
		for bit, dir in pairs(WHEEL) do
			if (b & bit) ~= 0 then
				rolled(dir)
			end
		end
		return
	end
	if m == "\27" or m == "q" then
		running = false
	elseif m == "r" then
		restart()
	elseif KEY[m] then
		move(KEY[m])
	end
end

math.randomseed(sys.uptime_ms())
paint(true)

-- two ports, not one: a window system sends keys and window state on
-- the event port and pointer records on their own. Reading either alone
-- leaves half the input on the floor.
local ev = prog.events()
local ptr = prog.mouse()

if ev then
	thread.spawn(function()
		while running do
			local m, why = thread.await(ev)

			if why then
				break
			end
			event(m)
		end
		os.exit(0)
	end)
end

if ptr then
	thread.spawn(function()
		while running do
			local x, y, b = ptr.read()

			if not x then
				break
			end
			event(mouse.format(x, y, b, 0))
		end
	end)
end

if not ev then
	local stdin = prog.stdin()

	if stdin then
		thread.spawn(function()
			-- a line with something on it. An empty one is what
			-- the console already had queued when this started,
			-- and eof is a console that cannot say stop at all.
			while true do
				local l = stdin:read("l")

				if not l then
					return
				end
				if l ~= "" then
					break
				end
			end
			fb.fill(memdraw.rect(0, 0, W, H), 0x000000, true)
			os.exit(0)
		end)
	end
end

thread.run()
