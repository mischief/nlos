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

local sys = require("los.sys")
local thread = require("los.thread")

-- how far a tab advances. Eight, like every other terminal.
local TABSTOP = 8

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

-- one message per changed SPAN, which is usually one cell.
--
-- A whole row is 53 cells at 6x12, or 15264 bytes of BGRx, and a blit
-- costs several copies of what it carries. Repainting the row for each
-- character typed spends about 30KB on one keystroke, which is what
-- made typing visibly slow. A span of one cell is 288 bytes.
--
-- from and to are cell columns, `to` exclusive. The row is padded so a
-- span past the end of the text erases what was there.
function Cons:paintspan(y, from, to)
	if to <= from then
		return
	end

	local line = self.grid[y + 1] or ""

	if #line < to then
		line = line .. string.rep(" ", to - #line)
	end

	local pix, w, h = self.font.render(line:sub(from + 1, to),
	    self.fg, self.bg)

	post(self.fb, { op = "load",
	    r = { x = from * self.cw, y = y * self.ch, w = w, h = h },
	    data = pix })
end

function Cons:paintrow(y)
	self:paintspan(y, 0, self.cols)
end

function Cons:repaint()
	for y = 0, self.rows - 1 do
		self:paintrow(y)
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
		    color = self.fg })
	else
		-- just the cell it was drawn over
		self:paintspan(self.row, self.col, self.col + 1)
	end
end

function Cons:scroll()
	table.remove(self.grid, 1)
	self.grid[self.rows] = ""
	self.row = self.rows - 1

	-- a full repaint, because fb.scroll cannot help here: it needs to
	-- read the screen back, and this panel's SDO is routed nowhere
	-- (see src/platform/esp32/lcd.c). The grid is the only copy of
	-- what is on the glass, so moving it up means drawing it again.
	self:repaint()
	self.dirty = true
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
		return		-- no bell, no escape sequences: not a vt yet
	end

	local line = self.grid[self.row + 1]

	-- pad with spaces rather than concatenating blind: a write after a
	-- \r lands mid-line, and Lua has no way to index past the end.
	if #line < self.col then
		line = line .. string.rep(" ", self.col - #line)
	end
	self.grid[self.row + 1] = line:sub(1, self.col) .. c ..
	    line:sub(self.col + 2)
	self.col = self.col + 1
	if self.col >= self.cols then
		self.col = 0
		self.row = self.row + 1
		if self.row >= self.rows then
			self:scroll()
		end
	end
end

-- Painted once per write rather than once per character, and only over
-- the columns that changed. A prompt is one write of several bytes; a
-- line of typing is one character per write, and either way this sends
-- one message for the span it touched.
function Cons:write(s)
	local first, firstcol = self.row, self.col

	self:cursor(false)
	self.dirty = nil
	for i = 1, #s do
		self:putc(s:sub(i, i))
	end
	if self.dirty then
		-- the scroll repainted the grid as it stood; anything
		-- written after it lands on the row the cursor ended on,
		-- and that row still needs drawing.
		self:paintrow(self.row)
	elseif self.row == first then
		local from = math.min(firstcol, self.col)
		local to = math.max(firstcol, self.col)

		self:paintspan(first, from, math.max(to, from + 1))
	else
		self:paintspan(first, firstcol, self.cols)
		for y = first + 1, self.row do
			self:paintrow(y)
		end
	end
	self:cursor(true)
end

-- fb is a send right to task/fb.lua, keyport a receive right carrying
-- keystrokes (the kernel's devkbdport, granted as "kbd"), font is
-- los.font.
function M.new(o)
	local mode = thread.rpc(o.fb, { op = "mode" }).ok
	local cw, ch = o.font.size()
	local self = setmetatable({
		fb = o.fb, font = o.font,
		cw = cw, ch = ch,
		cols = mode.w // cw, rows = mode.h // ch,
		col = 0, row = 0, curon = false,
		fg = o.fg or 0xc0c0c0, bg = o.bg or 0x000000,
		grid = {},
	}, Cons)

	for i = 1, self.rows do
		self.grid[i] = ""
	end
	thread.rpc(self.fb, { op = "fill",
	    r = { x = 0, y = 0, w = mode.w, h = mode.h }, color = self.bg })

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
