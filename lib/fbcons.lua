-- fbcons: a console backend that draws glyphs, for lib/console.lua.
--
-- task/cons.lua binds a serial line to lib/console.lua; this binds a
-- framebuffer and a keyboard to the same thing. Both hand a program the
-- identical tty capability, so bin/vi.lua and the dos prompt never
-- learn which is underneath them -- that is the whole reason the tty
-- logic lives in console.lua and the device is injected.
--
-- What a backend owes console.lua:
--
--	write(s)	emit bytes to the far end
--	keyport		the receive right raw keystrokes arrive on
--	raw(on)		optional; a device that rewrites bytes on the way out
--
-- A framebuffer rewrites nothing, so there is no raw().
--
-- It knows about a grid of character cells and a cursor, and nothing
-- above it does: fb is rectangles and pixels (see task/fb.lua), and the
-- glyphs come from los.font, which is data rather than a device. This
-- file is the only place that knows a screen has lines.
--
-- It is the terminal emulator, not a pass-through: a serial backend
-- hands bytes to a host xterm that interprets them, but nothing sits
-- below this, so this file parses the escape sequences itself. A small
-- ANSI subset -- cursor motion, erase, and SGR colour -- so a program
-- that colours its output over the tty reaches the glass, since a proc
-- has no other path to the console than the byte stream.

local sys = require("los.sys")
local thread = require("los.thread")

-- how far a tab advances. Eight, like every other terminal.
local TABSTOP = 8

-- the 16 ANSI colours as 0xRRGGBB. 0-7 are normal, 8-15 the bright half
-- a bold attribute selects for the foreground.
local PALETTE = {
	[0] = 0x000000, [1] = 0xcc0000, [2] = 0x00cc00, [3] = 0xcccc00,
	[4] = 0x0000cc, [5] = 0xcc00cc, [6] = 0x00cccc, [7] = 0xcccccc,
	[8] = 0x555555, [9] = 0xff5555, [10] = 0x55ff55, [11] = 0xffff55,
	[12] = 0x5555ff, [13] = 0xff55ff, [14] = 0x55ffff, [15] = 0xffffff,
}

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

-- a missing or zero cursor-motion count means one.
local function atleast1(n)
	if not n or n == 0 then
		return 1
	end
	return n
end

-- split a CSI parameter string into numbers, an empty field reading 0.
-- "1;2" -> {1,2}, "" -> {0}, ";5" -> {0,5}.
local function params(parm)
	local t = {}

	for s in (parm .. ";"):gmatch("([^;]*);") do
		t[#t + 1] = tonumber(s) or 0
	end
	return t
end

-- a draw, without waiting for it to finish.
--
-- task/fb.lua answers ops that only return true when asked to and not
-- otherwise, so a console that does not need the answer should not pay
-- a round trip per glyph. Parking when the queue is full is what keeps
-- that from becoming an unbounded backlog: the writer waits for room
-- rather than dropping or spinning.
local function post(h, msg)
	while true do
		local ok, why = sys.send(h, msg)

		if ok or why ~= "full" then
			return
		end
		thread.parksend(h)
	end
end

local M = {}
local Cons = {}

Cons.__index = Cons

-- the foreground and background a cell would be written with now, after
-- the active reverse-video attribute.
function Cons:pen()
	if self.rev then
		return self.lbg, self.lfg
	end
	return self.lfg, self.lbg
end

-- paint a span, but only the cells that differ from what the glass
-- already shows.
--
-- A caller (a full-screen program like vi) redraws everything on every
-- keystroke; the panel is slow, and blitting a cell that is already
-- right is the cost that made that painful. So this keeps a shown grid
-- -- the character and colour last drawn into each cell -- and skips a
-- cell whose new value matches it. A keystroke that changes one glyph
-- draws one cell, not the row.
--
-- What does draw is split into runs of one colour, because los.font
-- renders a string with a single foreground and background; a whole row
-- is 53 cells at 6x12, or 15264 bytes of BGRx, and one blit carries
-- several copies of what it holds. An unchanged cell ends a run: drawing
-- across it would cost a blit to paint what is already there.
--
-- from and to are cell columns, `to` exclusive. The row is padded so a
-- span past the end of the text erases what was there.
function Cons:paintspan(y, from, to)
	if to <= from then
		return
	end

	local i = y + 1
	local line = self.grid[i] or ""

	if #line < to then
		line = line .. string.rep(" ", to - #line)
	end

	local fgc, bgc = self.fgc[i], self.bgc[i]
	local sch, sfg, sbg = self.shownch[i], self.shownfg[i], self.shownbg[i]
	local deffg, defbg = self.deffg, self.defbg

	-- does the glass already show cell c (0-based) as the grid wants it?
	local function same(c)
		return sch[c + 1] == line:byte(c + 1)
		    and sfg[c + 1] == (fgc[c + 1] or deffg)
		    and sbg[c + 1] == (bgc[c + 1] or defbg)
	end

	local c = from

	while c < to do
		if same(c) then
			c = c + 1
		else
			local fg = fgc[c + 1] or deffg
			local bg = bgc[c + 1] or defbg
			local e = c + 1

			while e < to and (fgc[e + 1] or deffg) == fg
			    and (bgc[e + 1] or defbg) == bg and not same(e) do
				e = e + 1
			end

			for k = c, e - 1 do
				sch[k + 1] = line:byte(k + 1)
				sfg[k + 1] = fg
				sbg[k + 1] = bg
			end

			local pix, w, h = self.font.render(line:sub(c + 1, e),
			    fg, bg)

			post(self.fb, { op = "load",
			    r = { x = c * self.cw, y = y * self.ch, w = w, h = h },
			    data = pix })
			c = e
		end
	end
end

function Cons:paintrow(y)
	self:paintspan(y, 0, self.cols)
end

function Cons:repaint()
	for y = 0, self.rows - 1 do
		self:paintrow(y)
	end
end

-- mark a span of a row as needing paint before the write returns. The
-- range widens as more of the row changes, so a write that touches one
-- row at several columns paints it once.
function Cons:dirtyspan(y, from, to)
	local d = self.dirty[y]

	if not d then
		self.dirty[y] = { from, to }
	else
		if from < d[1] then
			d[1] = from
		end
		if to > d[2] then
			d[2] = to
		end
	end
end

-- the cursor is a filled cell, undrawn by repainting the one cell it
-- covered. No blink: a timer for it would need a thread of its own, and
-- a solid block is legible without one.
function Cons:cursor(on)
	if self.curon == on then
		return
	end
	self.curon = on
	if on then
		post(self.fb, { op = "fill", r = { x = self.col * self.cw,
		    y = self.row * self.ch, w = self.cw, h = self.ch },
		    color = self.deffg })
		-- the block covers the cell's glyph, so the glass no longer
		-- shows its content; forget it, or paintspan would take the
		-- block for the character and leave it when the cursor moves.
		self.shownch[self.row + 1][self.col + 1] = nil
	else
		-- just the cell it was drawn over
		self:paintspan(self.row, self.col, self.col + 1)
	end
end

function Cons:scroll()
	table.remove(self.grid, 1)
	table.remove(self.fgc, 1)
	table.remove(self.bgc, 1)
	self.grid[self.rows] = ""
	self.fgc[self.rows] = {}
	self.bgc[self.rows] = {}
	self.row = self.rows - 1

	-- the grid moved up but the glass did not: fb.scroll cannot help,
	-- it needs to read the screen back and this panel's SDO is routed
	-- nowhere (see src/platform/esp32/lcd.c). So every cell on the
	-- glass is now wrong. Forget what it showed, then repaint puts it
	-- all back -- the one case the diff cannot spare, and why scrolling
	-- output stays the slow path until the panel scrolls in hardware.
	for i = 1, self.rows do
		self.shownch[i] = {}
		self.shownfg[i] = {}
		self.shownbg[i] = {}
	end
	self:repaint()

	-- the screen is current after the repaint; drop what was pending
	-- for the rows that just moved. Anything written next re-marks.
	self.dirty = {}
end

-- place one character at the cursor with the active colours, padding a
-- short row with default-coloured spaces so a write after a \r or a
-- cursor jump lands mid-line.
function Cons:setcell(y, col, c)
	local i = y + 1
	local line = self.grid[i]
	local fg, bg = self:pen()

	if #line < col then
		for k = #line, col - 1 do
			self.fgc[i][k + 1] = self.deffg
			self.bgc[i][k + 1] = self.defbg
		end
		line = line .. string.rep(" ", col - #line)
	end
	self.grid[i] = line:sub(1, col) .. c .. line:sub(col + 2)
	self.fgc[i][col + 1] = fg
	self.bgc[i][col + 1] = bg
end

-- blank a run of a row to spaces in the active background, the way an
-- erase leaves it. Rebuilds the row string once rather than per cell.
function Cons:clearrow(y, from, to)
	if to <= from then
		return
	end

	local i = y + 1
	local line = self.grid[i]
	local fg, bg = self:pen()

	if #line < to then
		line = line .. string.rep(" ", to - #line)
	end
	self.grid[i] = line:sub(1, from) .. string.rep(" ", to - from) ..
	    line:sub(to + 1)
	for c = from, to - 1 do
		self.fgc[i][c + 1] = fg
		self.bgc[i][c + 1] = bg
	end
	self:dirtyspan(y, from, to)
end

function Cons:putc(c)
	if c == "\n" then
		self.row = self.row + 1
		self.col = 0
		if self.row >= self.rows then
			self:scroll()
		end
		return
	elseif c == "\r" then
		self.col = 0
		return
	elseif c == "\8" then
		-- console.lua erases with "\8 \8", so the space that
		-- follows does the rubbing out; this only steps back.
		if self.col > 0 then
			self.col = self.col - 1
		end
		return
	elseif c == "\t" then
		-- to the next multiple of TABSTOP, writing spaces so the
		-- cells are cleared rather than skipped over
		local stop = math.min(self.col - self.col % TABSTOP +
		    TABSTOP, self.cols)

		while self.col < stop do
			self:putc(" ")
		end
		return
	elseif c < " " then
		return		-- other C0 controls have no glyph here
	end

	self:setcell(self.row, self.col, c)
	self:dirtyspan(self.row, self.col, self.col + 1)
	self.col = self.col + 1
	if self.col >= self.cols then
		self.col = 0
		self.row = self.row + 1
		if self.row >= self.rows then
			self:scroll()
		end
	end
end

-- ---- the escape parser ----
--
-- state persists across write() calls, because a program can emit an
-- escape in pieces: ESC in one write, [ and the rest in the next.

function Cons:sgr(p)
	for i = 1, #p do
		local n = p[i]

		if n == 0 then
			self.lfg, self.lbg = self.deffg, self.defbg
			self.bold, self.rev = false, false
		elseif n == 1 then
			self.bold = true
		elseif n == 22 then
			self.bold = false
		elseif n == 7 then
			self.rev = true
		elseif n == 27 then
			self.rev = false
		elseif n >= 30 and n <= 37 then
			self.lfg = PALETTE[n - 30 + (self.bold and 8 or 0)]
		elseif n == 39 then
			self.lfg = self.deffg
		elseif n >= 40 and n <= 47 then
			self.lbg = PALETTE[n - 40]
		elseif n == 49 then
			self.lbg = self.defbg
		elseif n >= 90 and n <= 97 then
			self.lfg = PALETTE[n - 90 + 8]
		elseif n >= 100 and n <= 107 then
			self.lbg = PALETTE[n - 100 + 8]
		end
		-- an unknown code (256-colour 38;5, truecolour 38;2) is
		-- skipped, leaving the colour as it was rather than wrong.
	end
end

function Cons:erasedisplay(mode)
	if mode == 0 then
		self:clearrow(self.row, self.col, self.cols)
		for y = self.row + 1, self.rows - 1 do
			self:clearrow(y, 0, self.cols)
		end
	elseif mode == 1 then
		for y = 0, self.row - 1 do
			self:clearrow(y, 0, self.cols)
		end
		self:clearrow(self.row, 0, self.col + 1)
	else
		for y = 0, self.rows - 1 do
			self:clearrow(y, 0, self.cols)
		end
	end
end

function Cons:eraseline(mode)
	if mode == 0 then
		self:clearrow(self.row, self.col, self.cols)
	elseif mode == 1 then
		self:clearrow(self.row, 0, self.col + 1)
	else
		self:clearrow(self.row, 0, self.cols)
	end
end

function Cons:reset()
	self.lfg, self.lbg = self.deffg, self.defbg
	self.bold, self.rev = false, false
	self.row, self.col = 0, 0
	for y = 0, self.rows - 1 do
		self:clearrow(y, 0, self.cols)
	end
end

-- dispatch one complete CSI sequence: the final byte and the parameter
-- string gathered before it.
function Cons:csi(final, parm)
	local p = params(parm)
	local n = p[1]

	if final == "A" then
		self.row = clamp(self.row - atleast1(n), 0, self.rows - 1)
	elseif final == "B" then
		self.row = clamp(self.row + atleast1(n), 0, self.rows - 1)
	elseif final == "C" then
		self.col = clamp(self.col + atleast1(n), 0, self.cols - 1)
	elseif final == "D" then
		self.col = clamp(self.col - atleast1(n), 0, self.cols - 1)
	elseif final == "G" then
		self.col = clamp(atleast1(n) - 1, 0, self.cols - 1)
	elseif final == "H" or final == "f" then
		self.row = clamp(atleast1(n) - 1, 0, self.rows - 1)
		self.col = clamp(atleast1(p[2]) - 1, 0, self.cols - 1)
	elseif final == "J" then
		self:erasedisplay(n or 0)
	elseif final == "K" then
		self:eraseline(n or 0)
	elseif final == "m" then
		self:sgr(p)
	elseif final == "s" then
		self.savedrow, self.savedcol = self.row, self.col
	elseif final == "u" then
		self.row = self.savedrow or 0
		self.col = self.savedcol or 0
	end
	-- an unrecognised final byte is dropped with its parameters.
end

-- one byte through the state machine. ESC opens an escape; ESC [ opens
-- a CSI whose parameters run until a byte in 0x40..0x7e ends it.
function Cons:feed(c)
	local st = self.state

	if st == "ground" then
		if c == "\27" then
			self.state = "esc"
		else
			self:putc(c)
		end
	elseif st == "esc" then
		if c == "[" then
			self.state, self.parm = "csi", ""
		elseif c == "c" then
			self:reset()
			self.state = "ground"
		else
			self.state = "ground"	-- unhandled ESC x
		end
	elseif st == "csi" then
		local b = c:byte()

		if b >= 0x40 and b <= 0x7e then
			self:csi(c, self.parm)
			self.state = "ground"
		else
			self.parm = self.parm .. c
		end
	end
end

-- Bytes in, glyphs on the glass. The cursor is lifted for the whole
-- write and set down once at the end, and only the rows a write touched
-- are painted -- one message per changed span, in column order.
function Cons:write(s)
	self:cursor(false)
	self.dirty = {}

	for i = 1, #s do
		self:feed(s:sub(i, i))
	end

	local ys = {}

	for y in pairs(self.dirty) do
		ys[#ys + 1] = y
	end
	table.sort(ys)
	for _, y in ipairs(ys) do
		local d = self.dirty[y]

		self:paintspan(y, d[1], d[2])
	end
	self:cursor(true)
end

-- fb is a send right to task/fb.lua, keyport a receive right carrying
-- keystrokes (the kernel's devkbdport, granted as "kbd"), font is
-- los.font.
function M.new(o)
	local mode = thread.rpc(o.fb, { op = "mode" }).ok
	local cw, ch = o.font.size()
	local deffg = o.fg or 0xc0c0c0
	local defbg = o.bg or 0x000000
	local self = setmetatable({
		fb = o.fb, font = o.font,
		cw = cw, ch = ch,
		cols = mode.w // cw, rows = mode.h // ch,
		col = 0, row = 0, curon = false,
		deffg = deffg, defbg = defbg,
		lfg = deffg, lbg = defbg,
		bold = false, rev = false,
		state = "ground", parm = "",
		dirty = {},
		grid = {}, fgc = {}, bgc = {},
		-- what the glass shows, per cell, so a redraw only sends the
		-- cells that changed. Empty means "nothing drawn yet", which
		-- the fill below makes true for the whole panel.
		shownch = {}, shownfg = {}, shownbg = {},
	}, Cons)

	for i = 1, self.rows do
		self.grid[i] = ""
		self.fgc[i] = {}
		self.bgc[i] = {}
		self.shownch[i] = {}
		self.shownfg[i] = {}
		self.shownbg[i] = {}
	end
	thread.rpc(self.fb, { op = "fill",
	    r = { x = 0, y = 0, w = mode.w, h = mode.h }, color = self.defbg })

	-- what lib/console.lua injects itself into: a write, and a port to
	-- alt on. Nothing here is a method, because console.lua calls them
	-- as plain functions.
	return {
		write = function(s)
			self:write(s)
		end,
		keyport = o.keyport,
		cols = self.cols,
		rows = self.rows,
	}
end

return M
