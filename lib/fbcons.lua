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

local thread = require("los.thread")

local M = {}
local Cons = {}

Cons.__index = Cons

-- one message per row rather than per glyph. A row of 53 cells at 6x12
-- is 15264 bytes of BGRx, which is one fb.load and one SPI transfer;
-- the same row drawn a character at a time is 53 of each, and the round
-- trips dominate exactly as they did for the console's bulk read.
function Cons:paintrow(y)
	local line = self.grid[y + 1] or ""
	local pix, w, h = self.font.render(line ..
	    string.rep(" ", self.cols - #line), self.fg, self.bg)

	thread.rpc(self.fb, { op = "load",
	    r = { x = 0, y = y * self.ch, w = w, h = h }, data = pix })
end

function Cons:repaint()
	for y = 0, self.rows - 1 do
		self:paintrow(y)
	end
end

-- the cursor is drawn as a filled cell, and undrawn by repainting the
-- row under it. No blink: a timer for it would need a thread of its
-- own, and a solid block is legible without one.
function Cons:cursor(on)
	if self.curon == on then
		return
	end
	self.curon = on
	if on then
		thread.rpc(self.fb, { op = "fill", r = { x = self.col * self.cw,
		    y = self.row * self.ch, w = self.cw, h = self.ch },
		    color = self.fg })
	else
		self:paintrow(self.row)
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
	elseif c < " " then
		return		-- no tabs, no bell: not a vt yet
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

-- Painted once per write() rather than once per character: a prompt is
-- one write of several bytes, and repainting its row for each of them
-- is the difference between a console that keeps up and one that does
-- not.
function Cons:write(s)
	local first = self.row

	self:cursor(false)
	for i = 1, #s do
		self:putc(s:sub(i, i))
	end
	-- scroll() already repainted everything, and comparing rows is how
	-- this tells that from an ordinary write that stayed put.
	if self.row >= first then
		for y = first, self.row do
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
