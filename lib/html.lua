-- html: a page, as blocks of text and links.

-- Not a rendering engine and not a parser of the standard's tree: a
-- reader. What comes out is lib/doc.lua's blocks, the same ones gemtext
-- makes, so one viewer draws both. No CSS, no scripts, no images, no
-- grid: a table is its rows, and a cell is text beside the last.

-- Real pages are not well formed. Nothing here demands a close tag,
-- and an element it does not know is neither an error nor a block --
-- its text is simply the text around it.

local url = require("url")
local doc = require("doc")

local M = {}

-- ---- entities ----

local NAMED = {
	amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
	nbsp = " ", ndash = "-", mdash = "--", hellip = "...",
	lsquo = "'", rsquo = "'", ldquo = '"', rdquo = '"',
	copy = "(c)", reg = "(R)", trade = "(tm)", deg = "deg",
	middot = "-", bull = "*", laquo = "<<", raquo = ">>",
	times = "x", eacute = "\u{e9}", egrave = "\u{e8}",
}

function M.unescape(s)
	if not s:find("&", 1, true) then
		return s
	end
	return (s:gsub("&(#?[%w]+);?", function(name)
		local hex = name:match("^#[xX](%x+)$")
		local dec = name:match("^#(%d+)$")
		local n = hex and tonumber(hex, 16) or dec and tonumber(dec)

		if n then
			-- a codepoint no font here has is still better as
			-- itself than as the digits that named it
			local ok, c = pcall(utf8.char, n)

			return ok and c or ""
		end
		return NAMED[name:lower()] or ("&" .. name .. ";")
	end))
end

-- ---- tags ----

-- the tag's own text, from < to the > that is not inside a quoted
-- value: an attribute may hold either bracket.
local function tagend(s, i)
	local q = nil
	local j = i + 1

	while j <= #s do
		local c = s:sub(j, j)

		if q then
			if c == q then
				q = nil
			end
		elseif c == '"' or c == "'" then
			q = c
		elseif c == ">" then
			return j
		end
		j = j + 1
	end
	return nil
end

function M.attrs(raw)
	local a = {}

	for k, v in raw:gmatch('([%w:%-]+)%s*=%s*"([^"]*)"') do
		a[k:lower()] = v
	end
	for k, v in raw:gmatch("([%w:%-]+)%s*=%s*'([^']*)'") do
		if a[k:lower()] == nil then
			a[k:lower()] = v
		end
	end
	for k, v in raw:gmatch("([%w:%-]+)%s*=%s*([^%s\"'>]+)") do
		if a[k:lower()] == nil then
			a[k:lower()] = v
		end
	end
	return a
end

-- kind, and then what it carries: "text" a string, "open" a name and
-- the tag's raw text, "close" a name.
function M.tokens(s)
	local i = 1

	return function()
		if i > #s then
			return nil
		end

		local lt = s:find("<", i, true)

		if not lt then
			local t = s:sub(i)

			i = #s + 1
			return "text", t
		end
		if lt > i then
			local t = s:sub(i, lt - 1)

			i = lt
			return "text", t
		end
		if s:sub(i, i + 3) == "<!--" then
			local e = s:find("-->", i, true)

			i = e and e + 3 or #s + 1
			return "comment"
		end
		if s:sub(i, i + 1) == "<!" or s:sub(i, i + 1) == "<?" then
			local e = s:find(">", i, true)

			i = e and e + 1 or #s + 1
			return "decl"
		end

		local gt = tagend(s, i)

		if not gt then
			local t = s:sub(i)

			i = #s + 1
			return "text", t
		end

		local raw = s:sub(i + 1, gt - 1)

		i = gt + 1
		if raw:sub(1, 1) == "/" then
			return "close", (raw:match("^/%s*([%w:%-]+)") or "")
			    :lower()
		end

		local name = raw:match("^([%w:%-]+)")

		if not name then
			return "comment"
		end
		return "open", name:lower(), raw
	end
end

-- ---- what each element is ----

-- content that is not text at all. Their close tag is looked for
-- rather than parsed toward, since what is inside may contain anything.
local OPAQUE = { script = true, style = true, svg = true,
    noscript = true, template = true }

-- The links around a page rather than the page, by the standard's own
-- definition of these two. Dropping them is worth about a twelfth of
-- what a big article costs, which is not enough to take by default:
-- some sites put what you came for inside one.
local CHROME = { nav = true, footer = true }

local BLOCK = {
	p = "para", div = "para", section = "para", article = "para",
	header = "para", footer = "para", nav = "para", main = "para",
	aside = "para", figure = "para", figcaption = "para",
	form = "para", fieldset = "para", address = "para",
	dt = "para", dd = "para", tr = "para", caption = "para",
	li = "item", blockquote = "quote", pre = "pre",
	h1 = "head", h2 = "head", h3 = "head",
	h4 = "head", h5 = "head", h6 = "head",
}

local HEADLEVEL = { h1 = 1, h2 = 2, h3 = 3, h4 = 3, h5 = 3, h6 = 3 }

-- ---- the reader ----

local P = {}

P.__index = P

local function new(base)
	return setmetatable({
		blocks = {},
		cur = nil,
		links = {},		-- the open <a> hrefs, innermost last
		pre = 0,
		base = base,
		ol = {},		-- one counter per open <ol>
	}, P)
end

function P:flush()
	local b = self.cur

	self.cur = nil
	if not b then
		return
	end
	-- the space before a close tag is the source's, like the one
	-- after the open tag was
	if b.n > 0 and b.kind ~= "pre" then
		b.text[b.n] = b.text[b.n]:gsub(" $", "")
	end
	for i = 1, b.n do
		if b.text[i]:match("%S") then
			self.blocks[#self.blocks + 1] = b
			return
		end
	end
end

function P:start(kind, opts)
	self:flush()
	self.cur = doc.block(kind, opts)
end

function P:text(s)
	if s == "" then
		return
	end
	if not self.cur then
		self.cur = doc.block("para")
	end

	-- an <a> with nothing to point at is held as false, so that its
	-- close tag still has something to pop
	local link = self.links[#self.links] or nil

	if self.pre > 0 then
		doc.run(self.cur, s, link)
		return
	end
	s = s:gsub("%s+", " ")
	-- space at the front of a block is the indentation of the source,
	-- not of the page
	if self.cur.n == 0 then
		s = s:gsub("^ ", "")
	end
	doc.run(self.cur, s, link)
end

function P:href(a)
	local h = a.href

	if not h or h == "" or h:sub(1, 1) == "#" then
		return nil
	end
	if h:lower():match("^javascript:") then
		return nil
	end
	return self.base and url.resolve(self.base, h) or h
end

function P:open(name, raw)
	local a = M.attrs(raw)

	if name == "base" and a.href then
		self.base = self.base and url.resolve(self.base, a.href)
		    or a.href
		return
	end
	if name == "br" then
		local kind = self.cur and self.cur.kind or "para"

		self:start(kind)
		return
	end
	if name == "hr" then
		self:flush()
		self.blocks[#self.blocks + 1] = doc.block("rule")
		return
	end
	if name == "a" then
		self.links[#self.links + 1] = self:href(a) or false
		return
	end
	if name == "img" then
		local alt = a.alt and M.unescape(a.alt) or nil

		if alt and alt ~= "" then
			self:text("[" .. alt .. "]")
		end
		return
	end
	if name == "ol" then
		self.ol[#self.ol + 1] = 0
		self:flush()
		return
	end
	if name == "ul" then
		self.ol[#self.ol + 1] = false
		self:flush()
		return
	end
	if name == "td" or name == "th" then
		-- a cell is text beside the last, not a column: there is
		-- one column here and it is the screen
		if self.cur and self.cur.n > 0 then
			doc.run(self.cur, " ")
		end
		return
	end

	local kind = BLOCK[name]

	if not kind then
		return
	end
	if kind == "pre" then
		self.pre = self.pre + 1
		self:start("pre")
		return
	end
	if kind == "item" then
		local n = self.ol[#self.ol]
		local depth = #self.ol > 0 and #self.ol or 1

		if n then
			n = n + 1
			self.ol[#self.ol] = n
			self:start("item", { level = depth,
			    marker = n .. ". " })
		else
			self:start("item", { level = depth })
		end
		return
	end
	self:start(kind, { level = HEADLEVEL[name] })
end

function P:close(name)
	if name == "a" then
		if #self.links > 0 then
			self.links[#self.links] = nil
		end
		return
	end
	if name == "ol" or name == "ul" then
		if #self.ol > 0 then
			self.ol[#self.ol] = nil
		end
		self:flush()
		return
	end
	if name == "pre" then
		if self.pre > 0 then
			self.pre = self.pre - 1
		end
		self:flush()
		return
	end
	if BLOCK[name] then
		self:flush()
	end
end

-- How much of a page becomes blocks. The bytes are bounded by whoever
-- fetched them; this bounds what those bytes expand into, which is a
-- table per block and another per run and is where a hostile page
-- would do its damage.
M.MAXBLOCKS = 4000

-- parse(html, opts) -> blocks, info
--
-- opts.base is the page's own url, which is what a relative href is
-- resolved against. info carries the title, the base as it ended up,
-- and whether a bound cut it short.
function M.parse(html, opts)
	opts = opts or {}

	local p = new(opts.base)
	local info = {}
	local max = opts.maxblocks or M.MAXBLOCKS
	local skip, title = nil, nil

	for kind, a, b in M.tokens(html) do
		if #p.blocks >= max then
			info.truncated = "blocks"
			break
		end
		if skip then
			if kind == "close" and a == skip then
				skip = nil
			end
		elseif kind == "text" then
			if title then
				title = title .. a
			else
				p:text(M.unescape(a))
			end
		elseif kind == "open" then
			if OPAQUE[a] or (opts.nochrome and CHROME[a]) then
				skip = a
			elseif a == "title" then
				title = ""
			else
				p:open(a, b)
			end
		elseif kind == "close" then
			if a == "title" and title then
				info.title = M.unescape(title)
				    :gsub("%s+", " "):match("^%s*(.-)%s*$")
				title = nil
			else
				p:close(a)
			end
		end
	end
	p:flush()
	info.base = p.base
	return p.blocks, info
end

return M
