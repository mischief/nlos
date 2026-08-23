-- doc: a document as blocks of inline runs, and the fold that turns
-- them into lines a panel can draw.

-- A block is a paragraph, a heading, a list item, a quote or
-- preformatted text. Its content is runs, and a run may carry a link.
-- That is the whole model: no boxes, no floats, one column.

-- What comes back is lines, each with the spans that fall on it. A
-- link crossing a fold is two spans on two lines, which is what makes
-- "what is under this cell" answerable without laying out again.

local M = {}

-- a column is a codepoint, not a byte
local function wlen(s)
	return utf8.len(s) or #s
end

local function wsub(s, i, j)
	local a = utf8.offset(s, i)
	local b = j and utf8.offset(s, j + 1)

	if not a then
		return s:sub(i, j)
	end
	return s:sub(a, b and b - 1 or nil)
end

M.len = wlen
M.sub = wsub

-- ---- building ----

-- A run is two array slots, not a table of its own. Measured: a table
-- per run costs about 120 bytes before its text, and a page is
-- thousands of them -- which was two thirds of what a document held.
function M.block(kind, opts)
	local b = { kind = kind, n = 0, text = {}, link = {} }

	for k, v in pairs(opts or {}) do
		b[k] = v
	end
	return b
end

function M.run(b, text, link)
	if text == "" then
		return b
	end

	local i = b.n
	local l = link or false

	-- Adjacent text pointing at the same place is one run. A page
	-- splits a sentence across a dozen inline elements that change
	-- nothing a reader can see, and each would otherwise cost a slot
	-- and a string of its own.
	if i > 0 and b.link[i] == l then
		b.text[i] = b.text[i] .. text
		return b
	end
	i = i + 1
	b.n = i
	b.text[i] = text
	-- false, not nil: a nil would leave a hole an array part cannot
	-- keep, and every later run would move into the hash part
	b.link[i] = l
	return b
end

function M.runlink(b, i)
	local l = b.link[i]

	return l ~= false and l or nil
end

local NOMARKS = {}

-- The block's text, and where each run sits in it, in columns.
--
-- Run once a block per scroll, so the one-run case takes the string
-- that is already there rather than concatenating a copy of it: most
-- blocks are one run, and a copy apiece is what a scroll costs.
local function flatten(b)
	if b.n == 1 then
		local link = b.link[1]

		if not link then
			return b.text[1], NOMARKS
		end
		return b.text[1], { { from = 1, to = wlen(b.text[1]),
		    link = link } }
	end

	local parts, at, marks = {}, 1, {}

	for i = 1, b.n do
		local text, link = b.text[i], b.link[i]
		local n = wlen(text)

		parts[i] = text
		if link then
			marks[#marks + 1] = { from = at, to = at + n - 1,
			    link = link }
		end
		at = at + n
	end
	return table.concat(parts), marks
end

-- ---- folding ----

local PREFIX = {
	head = { [1] = "", [2] = "  ", [3] = "    " },
	item = "* ",
	quote = "> ",
}

-- the runs that fall on one folded line, moved into its columns. off
-- is where the line starts in the block, in columns.
-- most lines of most pages carry no link, and a table apiece to say so
-- is a table apiece. Shared because nothing ever adds to it.
local NOSPANS = {}

local function spansfor(marks, off, len, indent)
	if #marks == 0 then
		return NOSPANS
	end

	local out = nil

	for _, m in ipairs(marks) do
		local a = m.from > off and m.from or off
		local b = m.to < off + len - 1 and m.to or off + len - 1

		if a <= b then
			out = out or {}
			out[#out + 1] = {
				from = a - off + indent + 1,
				to = b - off + indent + 1,
				link = m.link,
			}
		end
	end
	return out or NOSPANS
end

-- Shared rather than made per call: fold runs once a block and a
-- scroll folds every block it passes over, so a closure here is a
-- closure a screenful of times.
local function space(text, i)
	local c = string.byte(text, i)

	return c == 32 or c == 9 or c == 10 or c == 13
end

local function colspan(text, i, j)
	if j < i then
		return 0
	end
	return utf8.len(text, i, j) or (j - i + 1)
end

-- Greedy, on spaces, and a word longer than the line is broken rather
-- than left to run off it.
--
-- Prefix and body go to emit apart, joined only by a caller that wants
-- the line: counting, or scrolling past a long block to reach a
-- window, then costs no string at all.
local function fold(text, marks, width, first, cont, emit)
	if width < 4 then
		width = 4
	end
	if text == "" then
		emit(first, "", 0, 0, #first)
		return
	end

	local byte = string.byte
	local n = #text
	local pre, room = first, width - wlen(first)
	local p, pcol = 1, 1

	while p <= n and space(text, p) do
		p = p + 1
		pcol = pcol + 1
	end

	while p <= n do
		local at, taken, last = p, 0, nil

		while at <= n do
			local sp = at

			while sp <= n and not space(text, sp) do
				sp = sp + 1
			end

			local add = colspan(text, at, sp - 1)
			local sep = at > p and 1 or 0

			if taken + sep + add > room then
				break
			end
			taken = taken + sep + add
			last = sp - 1
			at = sp
			while at <= n and space(text, at) do
				at = at + 1
			end
		end

		if not last then
			-- one word wider than the line: cut it where the line
			-- ends, since nothing below can wrap it
			local upto = p

			taken = 0
			while upto <= n and taken < room do
				upto = upto + 1
				while upto <= n and byte(text, upto) >= 0x80
				    and byte(text, upto) < 0xc0 do
					upto = upto + 1
				end
				taken = taken + 1
			end
			last, at = upto - 1, upto
		end

		emit(pre, text:sub(p, last), pcol, taken, wlen(pre))
		pcol = pcol + taken + colspan(text, last + 1, at - 1)
		p = at
		pre, room = cont, width - wlen(cont)
	end
end

-- one block, folded. emit(text, off, len, indent) once a line, which
-- is the only place a line's shape is decided: M.wrap keeps what it
-- makes and M.layout only counts.
local function foldblock(b, cols, take)
	local text, marks = flatten(b)
	-- the marks travel with each line rather than being returned
	-- after them: a caller building lines needs them as they come
	local emit = function(pre, body, off, len, indent)
		take(pre, body, off, len, indent, marks)
	end

	do
		if b.kind == "pre" then
			-- never folded: wrapping preformatted text wraps
			-- the picture it draws
			local last = nil

			for line in (text .. "\n"):gmatch("(.-)\n") do
				if last then
					emit("", last, 1, wlen(last), 0)
				end
				last = line
			end
			if last and last ~= "" then
				emit("", last, 1, wlen(last), 0)
			end
		elseif b.kind == "rule" then
			emit("", string.rep("-", cols), 0, 0, 0)
		elseif b.kind == "head" then
			local p = PREFIX.head[b.level or 1] or ""

			fold(text, marks, cols, p, p, emit)
		elseif b.kind == "item" then
			-- a nested list is indented, and an ordered one is
			-- numbered where a bulleted one is not
			local ind = string.rep("  ", (b.level or 1) - 1)
			local mark = ind .. (b.marker or PREFIX.item)

			fold(text, marks, cols, mark,
			    string.rep(" ", wlen(mark)), emit)
		elseif b.kind == "quote" then
			fold(text, marks, cols, PREFIX.quote, PREFIX.quote,
			    emit)
		else
			fold(text, marks, cols, "", "", emit)
		end
	end
	return marks
end

-- one line, as a viewer wants it. Spans are 1-based columns into text,
-- and the prefix is joined on here because this is where a line is
-- first wanted whole.
local function line(b, i, pre, body, off, len, indent, marks)
	return {
		text = pre == "" and body or (pre .. body),
		kind = b.kind,
		level = b.level,
		block = i,
		spans = spansfor(marks, off, len, indent),
	}
end

-- every block folded and kept. What a caller that holds a small page
-- wants; a big one wants M.layout, which keeps nothing.
function M.wrap(blocks, cols)
	local lines = {}

	for i, b in ipairs(blocks) do
		foldblock(b, cols, function(pre, body, off, len, indent,
		    marks)
			lines[#lines + 1] = line(b, i, pre, body, off, len,
			    indent, marks)
		end)
	end
	return lines
end

-- ---- an index, for a page too big to keep folded ----

-- How many lines each block folds to, and nothing else. A page is read
-- through a window of twenty lines and only those need to exist; the
-- rest is two integers a block, which is what makes a long article
-- cost what its text costs rather than what its layout would.
local Layout = {}

Layout.__index = Layout

function M.layout(blocks, cols)
	local L = setmetatable({
		blocks = blocks,
		cols = cols,
		count = {},
		first = {},
		nlines = 0,
	}, Layout)

	for i, b in ipairs(blocks) do
		local n = 0

		foldblock(b, cols, function()
			n = n + 1
		end)
		L.count[i] = n
		L.first[i] = L.nlines + 1
		L.nlines = L.nlines + n
	end
	return L
end

-- which block holds a line, by walking from a guess. Lines are asked
-- for in order, so the guess is nearly always right.
function Layout:blockat(lineno)
	if lineno < 1 or lineno > self.nlines then
		return nil
	end

	local i = self.at or 1

	if self.first[i] and self.first[i] > lineno then
		i = 1
	end
	while i <= #self.blocks do
		if lineno < self.first[i] + self.count[i] then
			self.at = i
			return i, lineno - self.first[i] + 1
		end
		i = i + 1
	end
	return nil
end

-- n lines from lineno, folded now and thrown away by the caller when
-- the screen next changes
function Layout:lines(lineno, n)
	local out = {}
	local i = self:blockat(lineno)

	if not i then
		return out
	end
	while i <= #self.blocks and #out < n do
		local b = self.blocks[i]
		local at = self.first[i]

		-- a line before the window costs nothing: the strings that
		-- would have made it are never joined
		foldblock(b, self.cols, function(pre, body, off, len, indent,
		    marks)
			if at >= lineno and #out < n then
				out[#out + 1] = line(b, i, pre, body, off,
				    len, indent, marks)
			end
			at = at + 1
		end)
		i = i + 1
	end
	return out
end

-- what is under a cell, without folding anything but the one block
function Layout:linkat(lineno, col)
	local got = self:lines(lineno, 1)

	return M.linkat(got[1], col)
end

-- the links, in the order they are read. Not stored: a run already
-- knows where it points, so the nth link is a walk and not a table.
function Layout:link(n)
	local seen, at = {}, 0

	for _, b in ipairs(self.blocks) do
		for i = 1, b.n do
			local l = b.link[i]

			if l and not seen[l] then
				seen[l] = true
				at = at + 1
				if at == n then
					return l
				end
			end
		end
	end
	return nil
end

-- every link to its number, in one pass. The only thing here that
-- grows with the page, so it is built by whoever needs to name a link
-- and not by whoever only draws.
function Layout:linkmap()
	local map, n = {}, 0

	for _, b in ipairs(self.blocks) do
		for i = 1, b.n do
			local l = b.link[i]

			if l and not map[l] then
				n = n + 1
				map[l] = n
			end
		end
	end
	return map, n
end

function Layout:nlinks()
	local seen, n = {}, 0

	for _, b in ipairs(self.blocks) do
		for i = 1, b.n do
			local l = b.link[i]

			if l and not seen[l] then
				seen[l] = true
				n = n + 1
			end
		end
	end
	return n
end

-- what is under a cell: the link whose span covers that column, or
-- nil. This is the whole reason a line keeps its spans.
function M.linkat(line, col)
	if not line or not line.spans then
		return nil
	end
	for _, s in ipairs(line.spans) do
		if col >= s.from and col <= s.to then
			return s.link
		end
	end
	return nil
end

-- every link in the document, in the order it is read, so a caller can
-- number them and a reader can name one
function M.links(lines)
	local seen, out = {}, {}

	for _, l in ipairs(lines) do
		for _, s in ipairs(l.spans or {}) do
			if not seen[s.link] then
				seen[s.link] = #out + 1
				out[#out + 1] = s.link
			end
			s.no = seen[s.link]
		end
	end
	return out
end

return M
