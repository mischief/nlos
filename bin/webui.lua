-- webui: read a web page on the panel.

--	a link is coloured where it sits -- touch one to follow it
--	the square in the corner, or ?, is the menu and the keys it names
--	/ searches, a digit names a link, enter follows it
--	the trackball scrolls, q leaves

-- The reading is lib/web.lua: no CSS, no scripts, no images. A link
-- here is a span inside a paragraph rather than a whole line, so the
-- hit test is a cell and not a row, and a line is drawn in pieces.

-- Nothing is held that does not have to be. The page is parsed as it
-- arrives and never exists as one string; lib/doc.lua keeps an index
-- rather than lines, and the twenty on the glass are folded when they
-- are asked for.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local web = require("web")
local doc = require("doc")
local html = require("html")
local url = require("url")
local menu = require("menu")

local fb = prog.screen()

local function die(s)
	io.stderr:write("webui: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no framebuffer on this machine")
end

local net = prog.net()
local dns = prog.dns()
local rand = prog.rand()

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local HEAD, LINK, QUOTE, PRE = 0x7fdbff, 0x60a0e0, 0x80c090, 0xa0a0b0

local FW, FH = 6, 12
local ROWH = FH + 1
local MARGIN = 2
local TOP = ROWH + 3
local FOOT = H - ROWH
local COLS = (W - MARGIN * 2) // FW
local ROWS = (FOOT - TOP) // ROWH

local SEARCH = "https://lite.duckduckgo.com/lite/?q="

-- What a page may take of what is left, asked fresh before each fetch
-- because the answer moves. A page big enough to take the machine down
-- takes every other program's drawing with it -- a font call that
-- cannot allocate is how it shows -- so this is a bound on the machine
-- and not merely on this program.
local SHARE = 3

-- chunkavail, not memavail: the lua heap is carved from a pool that on
-- a board with psram is not the memory memavail reports. A T-Deck
-- browsing has 39K of the one and 842K of the other, and a page
-- budgeted against the first is a paragraph.
local function freeroom(st)
	if st.chunkavail and st.chunkavail > 0 then
		return st.chunkavail
	end
	return st.memavail
end

local function pagelimit()
	local ok, st = pcall(sys.stats)

	if not ok or type(st) ~= "table" then
		return nil
	end

	local free = freeroom(st)

	if not free or free <= 0 then
		return nil
	end

	local n = free // (SHARE * html.BLOCKCOST)

	if n < 120 then
		n = 120
	end
	if n > html.MAXBLOCKS then
		n = html.MAXBLOCKS
	end
	return n
end

-- the start page, as html, so it goes through the same reader a
-- fetched page does and there is no second path for the one page that
-- ships with the program
local HOME = [[
<h1>web</h1>
<p>A reader, not a browser: text and links, no scripts and no pictures.
Press / to search, or g to type an address.</p>
<ul>
<li><a href="https://lite.duckduckgo.com/lite/">DuckDuckGo, the lite one</a></li>
<li><a href="https://en.wikipedia.org/wiki/Special:Random">Wikipedia, something at random</a></li>
<li><a href="https://news.ycombinator.com/">Hacker News</a></li>
<li><a href="https://lite.cnn.com/">CNN, the text one</a></li>
<li><a href="http://info.cern.ch/hypertext/WWW/TheProject.html">The first web page</a></li>
</ul>
]]

local HOMEURL = "about:start"

-- ---- what is on the glass ----

local page = { url = HOMEURL, L = nil, title = nil }
local top = 1
local history = {}
local typing, typed, prompt = nil, "", ""
local article = true
local lastlimit = nil
local note = ""
local busy = false
local visible = true
local shown = {}

local function text(x, y, s, fg)
	if s == "" then
		return
	end

	local px, w, h = font.render(s, fg or FG, BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

local function tail(s, n)
	local len = utf8.len(s)

	if not len then
		return #s > n and s:sub(#s - n + 1) or s
	end
	if len <= n then
		return s
	end
	return s:sub(utf8.offset(s, len - n + 1))
end

local D = {
	fill = function(x, y, w, h, c)
		fb.fill({ x = x, y = y, w = w, h = h }, c, true)
	end,
	text = function(x, y, s, c)
		text(x, y, s, c)
	end,
}

local PAL = { bg = 0x1c1c24, fg = FG, dim = DIM, sel = 0x26304a,
    edge = DIM }

local BW = menu.BUTTON
local nav = menu.new({
	title = "web",
	top = ROWH + 2,
	w = W,
	h = H,
	rowh = ROWH,
	fw = FW,
	items = {
		{ id = "back", label = "back", key = "b" },
		{ id = "reload", label = "reload", key = "r" },
		{ id = "home", label = "start page", key = "h" },
		{ id = "search", label = "search", key = "/" },
		{ id = "url", label = "open a url", key = "g" },
		{ id = "whole", label = "whole page", key = "w" },
		{ id = "quit", label = "quit", key = "q" },
	},
})

local KIND = { head = HEAD, quote = QUOTE, pre = PRE }

-- a line in pieces, because a link is a run inside it and not the
-- whole of it. One render a piece, which is at most a few.
local function drawline(y, l)
	local base = KIND[l.kind] or FG

	if l.kind == "head" and l.level and l.level > 1 then
		base = DIM
	end
	if #l.spans == 0 then
		text(MARGIN, y, l.text, base)
		return
	end

	local at = 1

	for _, s in ipairs(l.spans) do
		if s.from > at then
			text(MARGIN + (at - 1) * FW, y,
			    doc.sub(l.text, at, s.from - 1), base)
		end
		text(MARGIN + (s.from - 1) * FW, y,
		    doc.sub(l.text, s.from, s.to), LINK)
		at = s.to + 1
	end
	if at <= doc.len(l.text) then
		text(MARGIN + (at - 1) * FW, y, doc.sub(l.text, at), base)
	end
end

local function drawbar()
	fb.fill({ x = 0, y = 0, w = W, h = ROWH }, BG, true)
	menu.drawbutton(D, 0, 1, nav:isopen() and HEAD or DIM, BG)
	text(BW + MARGIN, 1, tail(page.title or page.url, COLS - 2),
	    busy and DIM or HEAD)
	fb.fill({ x = 0, y = ROWH + 1, w = W, h = 1 }, DIM)
end

local function drawfoot()
	fb.fill({ x = 0, y = FOOT, w = W, h = ROWH }, BG, true)
	fb.fill({ x = 0, y = FOOT - 1, w = W, h = 1 }, DIM)
	if typing then
		text(MARGIN, FOOT, tail(prompt .. typed, COLS), FG)
	else
		text(MARGIN, FOOT, tail(note, COLS), DIM)
	end
end

local shownlines = {}

local function drawbody(all)
	if all then
		fb.fill({ x = 0, y = TOP, w = W, h = FOOT - TOP - 1 }, BG,
		    true)
		shown = {}
	end

	local got = page.L and page.L:lines(top, ROWS) or {}
	local seen = {}

	shownlines = got
	for i = 1, ROWS do
		local l = got[i]
		local key = l and (l.text .. "\1" .. l.kind) or ""
		local y = TOP + (i - 1) * ROWH

		seen[i] = key
		if shown[i] ~= key then
			fb.fill({ x = 0, y = y, w = W, h = ROWH }, BG, true)
			if l then
				drawline(y, l)
			end
		end
	end
	shown = seen
end

local function draw(all)
	if not visible then
		return
	end
	if all then
		fb.fill({ x = 0, y = 0, w = W, h = H }, BG, true)
	end
	drawbar()
	drawbody(all)
	drawfoot()
	nav:draw(D, PAL)
end

local function say(s)
	note = s
	if visible then
		drawfoot()
	end
end

-- ---- moving ----

local function scroll(by)
	local n = page.L and page.L.nlines or 0
	local last = math.max(1, n - ROWS + 1)
	local was = top

	top = top + by
	if top > last then
		top = last
	end
	if top < 1 then
		top = 1
	end
	if top ~= was then
		drawbody(false)
	end
end

local function show(u, blocks, info, keep)
	if not keep then
		history[#history + 1] = page.url
	end
	page = {
		url = u,
		title = info and info.title or nil,
		L = doc.layout(blocks, COLS),
	}
	top = 1

	local n = page.L:nlinks()

	-- what stopped it, and at what: "(part)" alone left nobody able to
	-- tell a bound doing its job from a page that is simply short
	local cut = info and info.truncated

	say((cut and ("(part: %s at %d) "):format(cut, lastlimit or 0) or "")
	    .. (n > 0 and (n .. " links, a digit names one") or "read"))
	draw(true)
	-- what the parse threw off is a page's worth of garbage, and the
	-- next thing this program does is wait
	collectgarbage()
end

local function go(u, keep)
	if busy then
		return
	end
	if u == HOMEURL then
		local blocks, info = html.parse(HOME, { base = HOMEURL })

		show(HOMEURL, blocks, info, keep)
		return
	end
	if not u:match("^%a+://") then
		u = "https://" .. u
	end

	local scheme = url.split(u).scheme

	if scheme ~= "http" and scheme ~= "https" then
		say("cannot open " .. tostring(scheme) .. " here")
		return
	end
	if not net then
		say("no network: the tray entry needs net = true")
		return
	end
	if scheme == "https" and not rand then
		say("no entropy, and tls needs some")
		return
	end

	busy = true
	say("fetching " .. tail(u, COLS - 10))
	drawbar()

	-- the article where the page says which part is it: on a screen
	-- this size, a menu of somewhere else is not what was asked for
	local wantmain = article

	lastlimit = pagelimit()

	-- in a thread of its own, so the panel still scrolls and still
	-- answers a key while a slow server thinks about it
	thread.spawn(function()
		local res, err = web.fetch(net, dns, u, {
			rand = rand,
			main = wantmain,
			maxblocks = lastlimit,
			onredirect = function(_, to)
				say("-> " .. tail(to, COLS - 4))
			end,
		})

		busy = false

		-- the handshake is over and the page is blocks now: the
		-- curves and the certificate parser are worth more as
		-- memory than as something already loaded
		local ok, tlstcp = pcall(require, "tlstcp")

		if ok then
			tlstcp.unload()
		end
		if not res then
			say(tostring(err))
			drawbar()
			return
		end
		if not res.blocks then
			say(res.status .. " " .. web.mime(res.headers))
			drawbar()
			return
		end
		show(res.url, res.blocks, res.info, keep)
	end)
end

local function back()
	local prev = table.remove(history)

	if not prev then
		say("nothing to go back to")
		return
	end
	go(prev, true)
end

local function followno(n)
	local u = page.L and page.L:link(n)

	if u then
		go(u)
	else
		say("no link " .. n)
	end
end

-- ---- the menu ----

local function closemenu()
	nav:hide()
	draw(true)
end

local function openmenu()
	nav:show()
	drawbar()
	nav:draw(D, PAL)
end

local function ask(what, p)
	typing, typed, prompt = what, "", p
	drawfoot()
end

local function pick(id)
	closemenu()
	if id == "back" then
		back()
	elseif id == "reload" then
		go(page.url, true)
	elseif id == "home" then
		go(HOMEURL)
	elseif id == "url" then
		ask("url", "url: ")
	elseif id == "search" then
		ask("search", "search: ")
	elseif id == "whole" then
		article = not article
		say(article and "the article, where a page marks one"
		    or "the whole page, menus and all")
		go(page.url, true)
	elseif id == "quit" then
		os.exit(0)
	end
end

-- ---- what is typed ----

local function commit()
	local what = typed
	local was = typing

	typing, typed, prompt = nil, "", ""
	drawfoot()
	if what == "" then
		return
	end
	if was == "link" then
		followno(tonumber(what) or -1)
	elseif was == "url" then
		go(what)
	elseif was == "search" then
		go(SEARCH .. url.escape(what))
	end
end

local function key(m)
	if nav:isopen() then
		local act, id = nav:key(m)

		if act == "pick" then
			pick(id)
		elseif act == "moved" then
			nav:draw(D, PAL)
		else
			closemenu()
		end
		return true
	end
	if typing then
		if m == "\r" or m == "\n" then
			commit()
		elseif m == "\27" then
			typing, typed, prompt = nil, "", ""
			drawfoot()
		elseif m == "\8" or m == "\127" then
			local n = utf8.len(typed)

			if n and n > 0 then
				typed = typed:sub(1, utf8.offset(typed, n) - 1)
				drawfoot()
			end
		elseif #m == 1 and m:byte() >= 32 then
			typed = typed .. m
			drawfoot()
		end
		return true
	end

	if m == "q" or m == "\27" then
		return false
	elseif m == "b" then
		back()
	elseif m == "r" then
		go(page.url, true)
	elseif m == "h" then
		go(HOMEURL)
	elseif m == "g" then
		ask("url", "url: ")
	elseif m == "/" then
		ask("search", "search: ")
	elseif m == "w" then
		pick("whole")
	elseif m == "?" then
		openmenu()
	elseif m:match("^%d$") then
		typing, typed, prompt = "link", m, "link: "
		drawfoot()
	elseif m == " " or m == "\27[B" then
		scroll(m == " " and ROWS - 1 or 1)
	elseif m == "\27[A" then
		scroll(-1)
	end
	return true
end

-- ---- input ----

local ev = prog.events()

if not ev then
	die("not running under the panel")
end

local point = prog.mouse()

if point then
	thread.spawn(function()
		local down = false

		while true do
			local x, y, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-(ROWS // 2))
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(ROWS // 2)
			end

			local pressed = (b & 7) ~= 0

			if pressed and not down then
				if nav:isopen() then
					local act, id = nav:click(x, y)

					if act == "pick" then
						pick(id)
					elseif act == "dismiss" then
						closemenu()
					end
				elseif menu.inbutton(x, y, 0, 1) then
					openmenu()
				elseif y >= TOP and y < FOOT then
					-- a cell, not a row: the link is
					-- wherever in the line it sits
					local row = (y - TOP) // ROWH + 1
					local col = (x - MARGIN) // FW + 1
					local u = doc.linkat(shownlines[row],
					    col)

					if u then
						go(u)
					end
				end
			end
			down = pressed
		end
	end)
end

thread.spawn(function()
	go(arg[1] or HOMEURL, true)
	draw(true)

	while true do
		local m = thread.recv(ev)

		-- os.exit, not a return: thread.run() ends when every
		-- thread does, and the pointer reader is parked forever
		if sys.hungup(ev) then
			os.exit(0)
		end
		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				draw(true)
			end
		elseif type(m) == "string" then
			if not key(m) then
				os.exit(0)
			end
		end
	end
end)

thread.run()
