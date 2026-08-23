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

-- the block's text, and where each run sits in it. Columns, so the
-- spans a fold produces are in the same unit the fold counts in.
local function flatten(b)
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

-- greedy, on spaces, and a word longer than the line is broken rather
-- than left to run off it
local function fold(text, marks, width, first, cont, emit)
	if width < 4 then
		width = 4
	end
	if text == "" then
		emit(first, 0, 0, #first)
		return
	end

	local pre, room = first, width - wlen(first)
	local out, at = "", 1
	local start = 1

	local function flush()
		emit(pre .. out, start, wlen(out), wlen(pre))
		pre, room = cont, width - wlen(cont)
		out = ""
	end

	for word in text:gmatch("%S+") do
		local n = wlen(word)

		-- where this word begins in the block, which is what a
		-- span is measured against
		at = (text:find(word, at, true) or at)

		local col = wlen(text:sub(1, at - 1)) + 1

		if out == "" then
			start, out = col, word
		elseif wlen(out) + 1 + n <= room then
			out = out .. " " .. word
		else
			flush()
			start, out = col, word
		end
		at = at + #word
		while wlen(out) > room do
			local head = wsub(out, 1, room)

			emit(pre .. head, start, room, wlen(pre))
			start = start + room
			out = wsub(out, room + 1)
			pre, room = cont, width - wlen(cont)
		end
	end
	if out ~= "" then
		flush()
	end
end

-- blocks to lines. Each line is { text, kind, block, spans, level },
-- and spans are 1-based columns into text.
function M.wrap(blocks, cols, opts)
	opts = opts or {}

	local lines = {}

	for i, b in ipairs(blocks) do
		local text, marks = flatten(b)
		local function emit(s, off, len, indent)
			lines[#lines + 1] = {
				text = s,
				kind = b.kind,
				level = b.level,
				block = i,
				spans = spansfor(marks, off, len, indent),
			}
		end

		if b.kind == "pre" then
			-- never folded: wrapping preformatted text wraps
			-- the picture it draws
			for line in (text .. "\n"):gmatch("(.-)\n") do
				emit(line, 1, wlen(line), 0)
			end
			lines[#lines] = nil
		elseif b.kind == "rule" then
			emit(string.rep("-", cols), 0, 0, 0)
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
	return lines
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
