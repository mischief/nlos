-- frame: text in a rectangle of cells, and where a point in it lands.
--
-- Plan 9's libframe without the boxes. There a frame is a list of runs
-- of runes with pixel widths, because the font is proportional and a
-- tab is a stop. Ours is one cell per codepoint, so a point is
-- arithmetic instead.

-- The shape is libframe's: the frame holds geometry and a selection,
-- the caller holds the text and draws. A frame that drew would need a
-- framebuffer, and nothing here could then be tested off a machine.

-- Offsets are codepoints, not bytes. An editor that splits a utf8
-- sequence corrupts the file it was opened on, and byte offsets are how
-- that happens: indices are right first, glyphs catch up later.

-- One cell per codepoint holds for every glyph src/font.c can draw. It
-- stops holding the day something double-width arrives, which is the
-- day the box list earns its keep.

local M = {}

local Frame = {}

Frame.__index = Frame

-- new(cols, rows) -- a frame that many cells across and down
function M.new(cols, rows)
	return setmetatable({
		cols = math.max(1, cols or 1),
		rows = math.max(1, rows or 1),
		text = "",
		lines = {},	-- wrapped: { boff, bend, coff, clen, line }
		top = 0,	-- first visible wrapped line, 0-based
		p0 = 0,		-- selection, in codepoints
		p1 = 0,
		nchars = 0,
	}, Frame)
end

-- ---- the text, wrapped ----
--
-- A wrapped line records where it starts in bytes (so a caller can cut
-- the string to draw it) and in codepoints (so a point maps to an
-- offset). Both, because the caller draws bytes and addresses runes.
function Frame:wrap()
	local t = self.text
	local lines = {}
	local boff, coff, col = 1, 0, 0
	local n = 0
	-- which line of the text a row came from, counted by newlines. A
	-- soft-wrapped row keeps its line's number, so a caller that holds
	-- something per line -- a colour, a speaker -- can find it without
	-- searching for the offset.
	local ln = 1

	-- broken before the codepoint that would not fit rather than
	-- after the one that filled the line: the break needs the byte
	-- index of what comes next, and that is only known once it is in
	-- hand.
	for p, c in utf8.codes(t) do
		n = n + 1
		if col == self.cols and c ~= 10 then
			lines[#lines + 1] = { boff = boff, bend = p - 1,
			    coff = coff, clen = col, hard = false, line = ln }
			boff = p
			coff = coff + col
			col = 0
		end
		if c == 10 then
			-- the newline ends its line and is not a cell. It
			-- is still a codepoint, so an offset lands on it
			-- and the next line starts past it.
			lines[#lines + 1] = { boff = boff, bend = p - 1,
			    coff = coff, clen = col, hard = true, line = ln }
			boff = p + 1
			coff = coff + col + 1
			col = 0
			ln = ln + 1
		else
			col = col + 1
		end
	end
	-- the tail, and an empty text still has one line: a frame with no
	-- lines has nowhere to put a cursor.
	if col > 0 or #lines == 0 or lines[#lines].hard then
		lines[#lines + 1] = { boff = boff, bend = #t,
		    coff = coff, clen = col, hard = false, line = ln }
	end
	self.lines = lines
	self.nchars = n
	return self
end

function M.settext(f, s)
	f.text = s or ""
	f.top = 0
	f.p0, f.p1 = 0, 0
	return f:wrap()
end

function Frame:settext(s)
	return M.settext(self, s)
end

-- the bytes of a visible line, 1-based from the top of the frame
function Frame:line(i)
	local l = self.lines[self.top + i]

	if not l then
		return nil
	end
	return self.text:sub(l.boff, l.bend), l
end

function Frame:nlines()
	return #self.lines
end

-- ---- points and offsets ----

-- charofpt(col, row) -- the offset closest to a cell, as libframe's
-- frcharofpt does: up and to the left of the point.
function Frame:charofpt(col, row)
	local l = self.lines[self.top + row + 1]

	if not l then
		l = self.lines[#self.lines]
		if not l then
			return 0
		end
		return l.coff + l.clen
	end
	if col < 0 then
		col = 0
	elseif col > l.clen then
		col = l.clen
	end
	return l.coff + col
end

-- ptofchar(off) -- where an offset sits, or nil where it is not on
-- screen. Two returns rather than a point, since a caller in cells has
-- no use for a table.
function Frame:ptofchar(off)
	for i = 1, self.rows do
		local l = self.lines[self.top + i]

		if not l then
			return nil
		end
		-- the end of a wrapped line and the start of the next are
		-- the same offset; the earlier line wins, so a cursor at a
		-- wrap sits where the text does.
		if off >= l.coff and off <= l.coff + l.clen then
			return off - l.coff, i - 1
		end
	end
	return nil
end

-- ---- selection ----
--
-- p0 == p1 is the cursor. One representation for both, which is what
-- lets a caller draw a tick and a highlight with the same test.
function Frame:select(a, b)
	if b < a then
		a, b = b, a
	end
	if a < 0 then
		a = 0
	end
	if b > self.nchars then
		b = self.nchars
	end
	self.p0, self.p1 = a, b
	return self
end

function Frame:cursor(off)
	return self:select(off, off)
end

-- what of a visible line is selected, as cell columns, or nil for none.
-- The caller paints that span and needs no notion of offsets to do it.
function Frame:selspan(i)
	local l = self.lines[self.top + i]

	if not l or self.p0 == self.p1 then
		return nil
	end

	local a = math.max(self.p0, l.coff)
	local b = math.min(self.p1, l.coff + l.clen)

	if a >= b then
		return nil
	end
	return a - l.coff, b - l.coff
end

-- ---- scrolling ----
--
-- Clamped so the last line stays in view: a frame scrolled past its own
-- text shows blank glass and gives a reader nothing to get back by.
function Frame:scroll(by)
	local most = #self.lines - self.rows
	local to = self.top + by

	if most < 0 then
		most = 0
	end
	if to < 0 then
		to = 0
	elseif to > most then
		to = most
	end

	local moved = to ~= self.top

	self.top = to
	return moved
end

-- put an offset on screen, scrolling only if it is not already there --
-- what a caller wants after typing or after a search.
function Frame:show(off)
	if self:ptofchar(off) then
		return false
	end
	for i, l in ipairs(self.lines) do
		if off >= l.coff and off <= l.coff + l.clen then
			local to = i - 1 - (self.rows // 2)

			return self:scroll(to - self.top)
		end
	end
	return false
end

-- ---- editing ----
--
-- By codepoint offset, so a caller that knows where the cursor is need
-- not know how wide the character under it was.
local function byteof(f, off)
	if off <= 0 then
		return 1
	end
	if off >= f.nchars then
		return #f.text + 1
	end
	return utf8.offset(f.text, off + 1)
end

function Frame:insert(off, s)
	local at = byteof(self, off)

	self.text = self.text:sub(1, at - 1) .. s .. self.text:sub(at)
	self:wrap()
	local n = utf8.len(s) or #s

	return off + n
end

function Frame:delete(a, b)
	if b < a then
		a, b = b, a
	end
	if a < 0 then
		a = 0
	end
	if b > self.nchars then
		b = self.nchars
	end
	if a == b then
		return a
	end

	local x, y = byteof(self, a), byteof(self, b)

	self.text = self.text:sub(1, x - 1) .. self.text:sub(y)
	self:wrap()
	return a
end

return M
