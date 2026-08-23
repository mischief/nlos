-- geminiui: read a gemini capsule on the panel.

--	a link is a row -- touch one to follow it
--	b back, r reload, h the start page, g type a url
--	a digit names a link; enter follows it
--	the trackball scrolls, q leaves

-- The protocol is lib/gemini.lua and the fetch is the same one
-- bin/gemini.lua does, redirects and all. What this adds is that a
-- link is a place on the glass: M.wrap hands back lines that each know
-- the link they came from, so the row under a finger is the answer.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local gemini = require("gemini")

local fb = prog.screen()

local function die(s)
	io.stderr:write("geminiui: " .. s .. "\n")
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
local HEAD, LINK, QUOTE, PRE, WARN =
    0x7fdbff, 0x60a0e0, 0x80c090, 0xa0a0b0, 0xc06060

local FW, FH = 6, 12
local ROWH = FH + 1
local MARGIN = 2
local TOP = ROWH + 3
local FOOT = H - ROWH
local COLS = (W - MARGIN * 2) // FW
local ROWS = (FOOT - TOP) // ROWH

-- where the start page points. Everything here answered a request for
-- its root while this was written; a capsule that has gone quiet is
-- the ordinary case in geminispace, so the list is a place to start
-- and not a promise.
local HOME = [[
# gemini

=> gemini://geminiprotocol.net/ Project Gemini: what this is
=> gemini://tlgs.one/search Search geminispace
=> gemini://kennedy.gemi.dev/search Kennedy: another search
=> gemini://station.martinrue.com/ Station: what people are posting
=> gemini://gemi.dev/ gemi.dev: tools and Gemipedia
=> gemini://skyjake.fi/ skyjake, who writes Lagrange
=> gemini://mozz.us/ mozz.us
=> gemini://gemini.ctrl-c.club/ ctrl-c club, a pubnix
=> gemini://republic.circumlunar.space/ Circumlunar Republic
]]

local HOMEURL = "about:start"

-- ---- what is on the glass ----

local page = { url = HOMEURL, lines = {} }
local top = 1
local history = {}
local typing = nil		-- "url", "answer" or "link" while typing
local typed = ""
local prompt = ""
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

-- the last n codepoints: a url is long and its tail is the part that
-- says which page this is
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

local COLOR = {
	link = LINK,
	quote = QUOTE,
	pre = PRE,
	head = HEAD,
}

local function linecolor(l)
	if l.kind == "head" then
		return l.level == 1 and HEAD or DIM
	end
	return COLOR[l.kind] or FG
end

local function drawbar()
	fb.fill({ x = 0, y = 0, w = W, h = ROWH }, BG, true)
	text(MARGIN, 1, tail(page.url, COLS), busy and DIM or HEAD)
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

local function drawbody(all)
	if all then
		fb.fill({ x = 0, y = TOP, w = W, h = FOOT - TOP - 1 }, BG,
		    true)
		shown = {}
	end

	local seen = {}

	for i = 1, ROWS do
		local l = page.lines[top + i - 1]
		local s = l and l.text or ""
		local key = s .. "\1" .. (l and l.kind or "")
		local y = TOP + (i - 1) * ROWH

		seen[i] = key
		if shown[i] ~= key then
			fb.fill({ x = 0, y = y, w = W, h = ROWH }, BG, true)
			text(MARGIN, y, s, l and linecolor(l) or FG)
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
end

local function say(s)
	note = s
	if visible then
		drawfoot()
	end
end

-- ---- moving ----

local function scroll(by)
	local last = math.max(1, #page.lines - ROWS + 1)
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

local function links(lines)
	local n = 0

	for _, l in ipairs(lines) do
		if l.link and l.link > n then
			n = l.link
		end
	end
	return n
end

local function show(url, lines, keep)
	if not keep then
		history[#history + 1] = page.url
	end
	page = { url = url, lines = lines }
	top = 1

	local n = links(lines)

	say(n > 0 and (n .. " links, a digit names one") or "")
	draw(true)
end

-- text that is not gemtext is still text: shown as it is, folded to
-- the width, rather than refused for the sake of its type
local function plainlines(body)
	local nodes = {}

	for line in (body .. "\n"):gmatch("(.-)\n") do
		nodes[#nodes + 1] = { kind = "pre", text = line }
	end
	return gemini.wrap(nodes, COLS)
end

local function answered(res, url, keep)
	local class = gemini.class(res.status)

	if class == gemini.INPUT then
		typing = "answer"
		typed = ""
		prompt = (res.meta ~= "" and res.meta or "input") .. "? "
		page = { url = res.url, lines = page.lines }
		drawbar()
		drawfoot()
		return
	end
	if class ~= gemini.SUCCESS then
		say(("%d %s"):format(res.status, res.meta))
		drawbar()
		return
	end

	local body = res:take()

	if gemini.isgemtext(res.meta) then
		show(url, gemini.wrap(gemini.parse(body), COLS,
		    { number = true }), keep)
	elseif res.meta:match("^text/") then
		show(url, plainlines(body), keep)
	else
		say("not text: " .. res.meta)
		drawbar()
	end
end

local function go(url, keep)
	if busy then
		return
	end
	if url == HOMEURL then
		show(HOMEURL, gemini.wrap(gemini.parse(HOME), COLS,
		    { number = true }), keep)
		return
	end

	local u, uerr = gemini.url(url)

	if not u then
		say(uerr .. ": " .. tail(url, COLS - 20))
		return
	end
	if not net then
		say("no network: the tray entry needs net = true")
		return
	end
	if not rand then
		say("no entropy, and tls needs some")
		return
	end

	busy = true
	say("fetching " .. tail(u.url, COLS - 10))
	drawbar()

	-- in a thread of its own, so the panel still scrolls and still
	-- answers a key while a slow capsule thinks about it
	thread.spawn(function()
		local res, err = gemini.fetch(net, dns, u.url, {
			rand = rand,
			onredirect = function(_, to)
				say("-> " .. tail(to, COLS - 4))
			end,
		})

		busy = false
		if not res then
			say(tostring(err))
			drawbar()
			return
		end
		answered(res, res.url, keep)
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

local function follow(ref)
	if not ref then
		return
	end

	local url = page.url == HOMEURL and ref
	    or gemini.resolve(page.url, ref)

	go(url)
end

local function followno(n)
	for _, l in ipairs(page.lines) do
		if l.link == n then
			follow(l.url)
			return
		end
	end
	say("no link " .. n)
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
	elseif was == "answer" then
		-- the answer to a prompt is the same page asked again with
		-- the reply on it, which is the whole of gemini's input
		local u = gemini.url(page.url)

		if u then
			u.query = gemini.escape(what)
			go(gemini.formaturl(u), true)
		end
	end
end

local function key(m)
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
		typing, typed, prompt = "url", "", "url: "
		drawfoot()
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
			local _, y, b = point.read()

			if not b then
				return
			end
			if (b & mouse.WHEELUP) ~= 0 then
				scroll(-(ROWS // 2))
			elseif (b & mouse.WHEELDOWN) ~= 0 then
				scroll(ROWS // 2)
			end

			local pressed = (b & 7) ~= 0

			-- the press edge, not the state: a finger held on a
			-- link should follow it once
			if pressed and not down and y >= TOP and y < FOOT then
				local l = page.lines[top + (y - TOP) // ROWH]

				if l and l.url then
					follow(l.url)
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
		-- thread does, and the pointer reader below is parked on a
		-- port forever. Returning from here leaves the proc up with
		-- nothing driving it.
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
