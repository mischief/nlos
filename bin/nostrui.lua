-- nostrui: a nostr client on the panel.
--
--	enter            publish what is typed, or /quiet to filter
--	esc              leave
--	touch the relay  connect, or connect again after a drop
--	touch the bar    show what the relay said
--	trackball        scroll

-- Reading is the whole of it plus posting: no follows, no profiles, no
-- private messages. A note is kind 1, which is what a relay hands over
-- when asked for nothing in particular.

-- Every event is verified before it is shown, at 233ms each: twelve
-- notes is about 2.9s of signatures inside 13s end to end. The rest is
-- the relay and the panel, which is why the timeline asks for few.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local frame = require("frame")
local json = require("json")
local nostr = require("nostr")
local nostrrelay = require("nostrrelay")

local N = prog.ns()
local fb = prog.screen()

local function die(s)
	io.stderr:write("nostrui: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no framebuffer")
end
if not N then
	die("no namespace")
end

-- either kind of network will do: sockets, or the websockets a machine
-- has when it has nothing under them.
local wsc = prog.ws()
local net = not wsc and (prog.net() or
    die("no network: /etc/dio.lua must say net = true")) or nil
local dns = prog.dns()
local rand = prog.rand()
local ptr = prog.mouse()

-- a directory of our own, because this keeps more than one file
local CONF = "/config/nostr"
local KEYFILE = CONF .. "/key"			-- an nsec, or hex
local RELAYFILE = CONF .. "/relay"		-- one wss:// url
local IGNOREFILE = CONF .. "/ignore"		-- an author a line

-- /config is empty on a freshly reamed partition, so the directory is
-- made on the way to the first write rather than assumed.
local function conf()
	if not N:stat(CONF) then
		local f = N:create(CONF, "rw", true)

		if f then
			f:close()
		end
	end
	return N:stat(CONF) ~= nil
end
-- where to ask when /config names nobody. Measured rather than
-- picked: relay.damus.io sits behind a proxy that answers 503 to
-- something like two connections in five, which reads as a machine
-- with no network. Any relay will do; this one answered every time.
local RELAY = "wss://nos.lol"
local WANT = 12					-- events per fetch

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local MINE, WHO, WARN = 0x60a0e0, 0xc9a0dc, 0xc06060

local FW, FH = 6, 12
local ROWH = FH + 2
local TOP = ROWH
local INPUT = H - ROWH
local rows = math.floor((INPUT - TOP) / ROWH)
local COLS = W // FW
local BUT1 = 1
local SCROLL = 4

-- ---- drawing ----

local function fill(x, y, w, h, color)
	fb.fill({ x = x, y = y, w = w, h = h }, color, true)
end

local function text(x, y, s, fg, bg)
	s = tostring(s or "")
	if s == "" then
		return
	end

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- ---- state ----

local F = frame.new(COLS, rows)
local lines = {}
local shownrow = {}
local typed = ""
local visible = true
local status = "idle"
local showlog = false
local relaylog = {}
local down = false
local relay, seckey, pubkey
local busy = false
local url = RELAY
local quiet = true		-- the open feed is mostly machines
local hidden = 0

-- punctuation this font does not have. A note from the wider internet
-- is full of it, and Spleen draws a box for every one.
local FOLD = {
	["\u{2018}"] = "'", ["\u{2019}"] = "'",
	["\u{201c}"] = '"', ["\u{201d}"] = '"',
	["\u{2013}"] = "-", ["\u{2014}"] = "--",
	["\u{2026}"] = "...", ["\u{00a0}"] = " ",
	["\u{2022}"] = "*", ["\u{2192}"] = "->",
}

local function plain(s)
	return (tostring(s):gsub("[\194-\244][\128-\191]*", FOLD))
end

-- ---- what a stranger sent ----

-- Note text comes from strangers. Control bytes are dropped, since the
-- panel has no use for them and a run of newlines would otherwise let
-- one note claim the whole screen.
local function sanitize(s)
	s = tostring(s):gsub("[\1-\8\11\12\14-\31\127]", "")
	s = s:gsub("\n\n\n+", "\n\n")
	return s
end

-- A relay's open feed is mostly machines. These judge the content
-- alone, so they can run before the signature: deciding not to spend
-- 233ms on a note is not the same as believing it.
local HEXRUN, PROSEMIN, WORDSMIN = 64, 40, 3

local function hexrun(s)
	local run = 0

	for i = 1, #s do
		local c = s:byte(i)

		if (c >= 48 and c <= 57) or (c >= 97 and c <= 102) then
			run = run + 1
			if run >= HEXRUN then
				return true
			end
		else
			run = 0
		end
	end
	return false
end

-- Prose has words in it. Bytes over 0x7f count as letters, so a script
-- that does not space its words is not mistaken for machine output.
local function prosepoor(s)
	if #s < PROSEMIN then
		return false
	end

	local words = 0

	for w in s:gmatch("[%a\128-\255]+") do
		if #w >= 3 then
			words = words + 1
		end
	end
	return words < WORDSMIN
end

local function paintbar()
	if not visible then
		return
	end

	local host = url:match("^wss?://([^/]+)") or url

	local right = status

	if hidden > 0 then
		right = ("%s  %d %s"):format(status, hidden,
		    quiet and "hidden" or "noisy")
	end
	fill(0, 0, W, ROWH, 0x202028)
	text(0, 0, "[" .. host .. "]", FG, 0x202028)
	text((#host + 3) * FW, 0, right, DIM, 0x202028)
end

local function paintinput()
	if not visible then
		return
	end
	fill(0, INPUT, W, ROWH, 0x181820)

	local s = "> " .. typed
	local n = utf8.len(s)

	if n and n > COLS then
		s = s:sub(utf8.offset(s, n - COLS + 1))
	end
	text(0, INPUT, s, busy and DIM or FG, 0x181820)
end

local function paintbody(all)
	if not visible then
		return
	end
	if all or showlog then
		fill(0, TOP, W, INPUT - TOP, BG)
		shownrow = {}
	end

	if showlog then
		local y = TOP

		text(0, y, "what the relay said", DIM)
		y = y + ROWH
		for i = math.max(1, #relaylog - rows + 2), #relaylog do
			if y + ROWH > INPUT then
				break
			end
			text(0, y, relaylog[i], DIM)
			y = y + ROWH
		end
		return
	end

	local seen = {}

	for i = 1, rows do
		local s, l = F:line(i)
		local y = TOP + (i - 1) * ROWH

		s = s or ""
		seen[i] = s
		if shownrow[i] ~= s then
			fill(0, y, W, ROWH, BG)
			text(0, y, s,
			    l and lines[l.line] and lines[l.line][2] or FG)
		end
	end
	shownrow = seen
end

local function retext()
	local parts = {}

	for i, l in ipairs(lines) do
		parts[i] = l[1]
	end
	F:settext(table.concat(parts, "\n"))
end

local function atbottom()
	return F.top >= F:nlines() - F.rows
end

local function say(s, color)
	local stick = atbottom()

	for one in plain(s):gmatch("[^\n]*") do
		lines[#lines + 1] = { one, color or FG }
	end
	while #lines > 300 do
		table.remove(lines, 1)
	end
	retext()
	if stick then
		F:scroll(F:nlines())
	end
	paintbody()
end

-- s as rows of at most cols, broken at the margin and at a newline.
-- Codepoints, not bytes: cutting mid-sequence draws a box for the
-- character it halved.
local function wrapped(s, cols)
	local out = {}

	for line in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
		local n = utf8.len(line)

		if n == nil then
			for i = 1, #line, cols do
				out[#out + 1] = line:sub(i, i + cols - 1)
			end
		elseif n == 0 then
			out[#out + 1] = ""
		else
			local i = 1

			while i <= n do
				local j = math.min(i + cols - 1, n)
				local a = utf8.offset(line, i)
				local b = j < n and utf8.offset(line, j + 1) - 1
				    or #line

				out[#out + 1] = line:sub(a, b)
				i = j + 1
			end
		end
	end
	return out
end

local function note(s)
	for _, l in ipairs(wrapped(plain(s), COLS)) do
		relaylog[#relaylog + 1] = l
	end
	while #relaylog > 100 do
		table.remove(relaylog, 1)
	end
	if showlog then
		paintbody(true)
	end
end

local function scroll(by)
	F:scroll(by)
	paintbody()
end

-- Machines repeat themselves and post on a metronome; people do
-- neither. This keys on the author, so it runs only after the
-- signature: judging an unverified pubkey would let anyone silence
-- anyone by forging notes in their name.
local RECENT, RATEWIN, RATEMAX = 4, 60, 10
local who = {}

local function flooding(pub, content, now)
	local n = who[pub]

	if not n then
		n = { seen = {}, at = 1, start = now, count = 0 }
		who[pub] = n
	end

	local repeated = false

	for _, h in ipairs(n.seen) do
		if h == content then
			repeated = true
		end
	end
	n.seen[n.at] = content
	n.at = n.at % RECENT + 1

	if now - n.start >= RATEWIN then
		n.start, n.count = now, 0
	end
	n.count = n.count + 1
	return repeated or n.count > RATEMAX
end

-- every relay carries the same note, and a reconnect asks again. Ids
-- already shown are remembered by a prefix; a collision would take
-- deliberate effort.
local shownid = {}
local nshown = 0

local function already(id)
	local k = id:sub(1, 16)

	if shownid[k] then
		return true
	end
	if nshown > 512 then
		shownid, nshown = {}, 0
	end
	shownid[k] = true
	nshown = nshown + 1
	return false
end

-- ---- keys ----
--
-- Made on first run and kept on /config, as bitchat's is, so a reflash
-- does not change who this board is. Written as an nsec rather than as
-- the raw 32 bytes: this is the one key here a person may want to carry
-- to another client, and nsec is the form every one of them reads.

local fresh = false

local function makekey()
	if not rand then return nil, "no entropy" end

	local sec, err = nostr.genkey(rand)

	if not sec then return nil, err end

	conf()

	local ok, werr = N:writefile(KEYFILE, nostr.nsec(sec) .. "\n")

	-- an unwritable /config is worth saying so: the key still works
	-- for this run, and is gone at the next boot.
	if not ok then return sec, werr or "could not be saved" end
	return sec
end

local key = N:readfile(KEYFILE)
local keyerr

if key then
	seckey = nostr.seckey(key)
	if not seckey then
		keyerr = KEYFILE .. " is not a key"
	end
else
	seckey, keyerr = makekey()
	fresh = seckey ~= nil
end

if seckey then
	pubkey = nostr.pubkey(seckey)
end

local savedurl = N:readfile(RELAYFILE)

if savedurl then
	savedurl = savedurl:gsub("%s+", "")
	if savedurl ~= "" then
		url = savedurl
	end
end

-- ---- the relay ----

-- one event onto the screen: who said it, then what they said. The
-- author is an npub, shortened, because 63 characters is more than the
-- screen has and the tail is the part that differs.
-- ---- who wrote it ----

-- A name is kind 0, which arrives later than the notes it labels. Until
-- it does, an author is an npub with its middle taken out; the tail is
-- the part that differs, so both ends are kept.
local names = {}
local wanted = {}

local function label(pub)
	if names[pub] then
		return names[pub]
	end

	local np = nostr.npub(nostr.unhex(pub)) or pub

	return np:sub(1, 12) .. ".." .. np:sub(-6)
end

-- the lines already on the screen carry the author they name, so a name
-- that arrives after them can be written in where the npub was.
local function relabel(pub)
	local touched = false

	for _, l in ipairs(lines) do
		if l.pub == pub then
			l[1] = plain(label(pub))
			touched = true
		end
	end
	if touched then
		retext()
		paintbody(true)
	end
end

local function show(ev, body)
	say(label(ev.pubkey), WHO)
	lines[#lines].pub = ev.pubkey
	say(body or ev.content)
	say("")
	if not names[ev.pubkey] then
		wanted[ev.pubkey] = true
	end
end

-- what a profile calls itself. The content is JSON inside JSON, and a
-- relay will hand over whatever an author put there, so this takes only
-- a name and takes it as text.
local function learn(ev)
	local ok, meta = pcall(json.decode, ev.content or "")

	if not ok or type(meta) ~= "table" then
		return
	end

	local name = meta.display_name or meta.name

	if type(name) ~= "string" or name == "" then
		return
	end
	name = sanitize(name):gsub("[\n\r]", " "):sub(1, 24)
	if name == "" then
		return
	end
	names[ev.pubkey] = name
	wanted[ev.pubkey] = nil
	relabel(ev.pubkey)
end

-- where the time goes, reported at the end because guessing was wrong:
-- signatures are a fifth of it, and the relay and the panel are the
-- rest.
-- A subscription outlives its EOSE: the relay keeps sending what
-- matches, so this loop runs until the connection goes rather than
-- until the stored events run out. Nothing reads the socket otherwise,
-- and the notes pile up in it unread.
local metasub, metaseq = nil, 0

local function askmeta()
	if metasub or not next(wanted) then
		return
	end

	local ask = {}

	for pub in pairs(wanted) do
		ask[#ask + 1] = pub
		wanted[pub] = nil
	end
	metaseq = metaseq + 1
	metasub = "m" .. metaseq
	relay:req(metasub, { kinds = { 0 }, authors = ask })
end

local function drain(t0)
	local shown, vms, first = 0, 0, nil
	local nms, sms = 0, 0
	local told = false

	while true do
		local n0 = sys.uptime_ms()
		local what, a, b, c = relay:next()

		nms = nms + (sys.uptime_ms() - n0)
		if not first then
			first = sys.uptime_ms() - t0
			note(("first message %d ms"):format(first))
		end

		if not what then
			note("gone: " .. tostring(a))
			status = "dropped"
			paintbar()
			relay = nil
			return
		end

		if what == "event" and a == metasub then
			-- a profile, verified like anything else: a name
			-- shown for somebody else's key is the whole of
			-- what an impersonator wants.
			local v0 = sys.uptime_ms()
			local ok = nostr.verify(b)

			vms = vms + (sys.uptime_ms() - v0)
			if ok and math.tointeger(b.kind) == 0 then
				learn(b)
			end
			goto continue
		elseif what == "event" then
			local body = sanitize(tostring(b.content or ""))

			-- before the signature, and deliberately: not
			-- spending 233ms on a payload blob is a decision
			-- about cost, not about whether to believe it.
			if quiet and (hexrun(body) or prosepoor(body)) then
				hidden = hidden + 1
				paintbar()
				goto continue
			end
			if already(tostring(b.id or "")) then
				goto continue
			end

			local v0 = sys.uptime_ms()
			local ok, why = nostr.verify(b)

			vms = vms + (sys.uptime_ms() - v0)
			if not ok then
				note("bad event: " .. tostring(why))
				goto continue
			end

			-- the author is worth trusting only now
			if quiet and flooding(b.pubkey, body,
			    math.tointeger(b.created_at) or 0) then
				hidden = hidden + 1
				paintbar()
				goto continue
			end

			local s0 = sys.uptime_ms()

			shown = shown + 1
			status = ("%d notes%s"):format(shown,
			    told and ", live" or "")
			paintbar()
			show(b, body)
			sms = sms + (sys.uptime_ms() - s0)
			-- a stranger who turned up after the first pass
			-- still deserves a name
			if told then
				askmeta()
			end
		elseif what == "eose" then
			if a == metasub then
				-- the names asked for have arrived; a
				-- profile the relay lacks never will
				relay:close_sub(metasub)
				metasub = nil
			elseif not told then
				local all = sys.uptime_ms() - t0

				-- the backlog is in; what follows is
				-- live, so the input line stops waiting
				told = true
				busy = false
				paintinput()
				note(("%d notes in %d ms: %d verifying, " ..
				    "%d the rest")
				    :format(shown, all, vms, all - vms))
				sys.log(("nostr: %d notes, %d ms: %d " ..
				    "verify, %d relay, %d draw, first %d ms")
				    :format(shown, all, vms, nms - vms,
				    sms, first or -1))
			end
			status = ("%d notes, live"):format(shown)
			paintbar()
			askmeta()
		elseif what == "notice" then
			note("notice: " .. tostring(a))
		elseif what == "ok" then
			note(("ok %s: %s"):format(tostring(a):sub(1, 8),
			    b and "accepted" or tostring(c)))
			say(b and "posted." or
			    ("the relay refused it: " .. tostring(c)),
			    b and DIM or WARN)
		elseif what == "closed" then
			note("closed: " .. tostring(b))
			return
		end
		::continue::
	end
end

local function connect()
	-- one at a time, and not a second while the first is still up:
	-- the subscription stays open, so being connected is the normal
	-- state rather than a step that finishes.
	if busy or (relay and relay:alive()) then
		return
	end
	busy = true
	status = "connecting"
	paintbar()

	thread.spawn(function()
		local c0 = sys.uptime_ms()
		local r, err

		-- a machine whose network is websockets opens one and
		-- hands it over; one with sockets builds the framing over
		-- a connection. The relay above cannot tell.
		if wsc then
			local sock, why = wsc.open(url)

			r, err = sock and nostrrelay.attach(sock, url), why
		else
			r, err = nostrrelay.connect(net, dns, url, rand)
		end

		if not r then
			say("! " .. tostring(err), WARN)
			status = "failed"
			busy = false
			paintbar()
			paintinput()
			return
		end
		local hs = sys.uptime_ms() - c0

		relay = r
		status = "asking"
		paintbar()
		note(("connected in %d ms"):format(hs))
		sys.log(("nostr: handshake %d ms"):format(hs))

		local t0 = sys.uptime_ms()
		local ok = relay:req("t", { kinds = { 1 }, limit = WANT })

		if not ok then
			say("! could not ask the relay", WARN)
		else
			drain(t0)
		end
		busy = false
		paintinput()
	end)
end

local function post(what)
	if not seckey then
		say("no key: " .. (keyerr or "none"), WARN)
		return
	end
	if not relay or not relay:alive() then
		say("not connected; touch the relay name", WARN)
		return
	end

	local now = sys.time and sys.time() or 0

	if not now or now < 1600000000 then
		say("the clock is unset, so a relay would refuse this", WARN)
		return
	end

	local ev, err = nostr.sign(seckey, 1, what, {}, now)

	if not ev then
		say("! " .. tostring(err), WARN)
		return
	end

	say("> " .. what, MINE)
	relay:publish(ev)
	note("sent " .. ev.id:sub(1, 8))
end

-- ---- the loop ----

local ev = prog.events()

if not ev then
	die("not running under the panel")
end

fill(0, 0, W, H, BG)
paintbar()
paintbody(true)
paintinput()

if seckey then
	if fresh then
		say("made a new identity, kept in " .. KEYFILE, DIM)
	end
	say("posting as " .. (nostr.npub(pubkey) or "?"):sub(1, 20) .. "..", DIM)
else
	say("no key (" .. (keyerr or "none") .. "), so this reads only.", WARN)
end
say("touch the relay name to connect.", DIM)

local function pointer()
	if not ptr then
		return
	end
	while true do
		local x, y, b = ptr.read()

		if not x then
			return
		end
		if b and (b & BUT1) ~= 0 and not down then
			if y < ROWH then
				local host = url:match("^wss?://([^/]+)") or url

				if x < (#host + 2) * FW then
					connect()
				else
					showlog = not showlog
					paintbody(true)
				end
			end
		end
		if b then
			down = (b & BUT1) ~= 0
		end
		if b and (b & mouse.WHEELUP) ~= 0 then
			scroll(-SCROLL)
		elseif b and (b & mouse.WHEELDOWN) ~= 0 then
			scroll(SCROLL)
		end
	end
end

local function ui()
	while true do
		local m, why = thread.await(ev)

		if why or sys.hungup(ev) then
			break
		end

		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				fill(0, 0, W, H, BG)
				paintbar()
				paintbody(true)
				paintinput()
			end
		elseif type(m) == "string" then
			-- typed rather than touched: the bar is two
			-- buttons already, and this is rare enough that
			-- it can afford a command.
			if typed == "/quiet" and (m == "\r" or m == "\n") then
				quiet = not quiet
				typed = ""
				say(("quiet is %s, %d held back so far")
				    :format(quiet and "on" or "off", hidden),
				    DIM)
				paintbar()
				paintinput()
			elseif m == "\r" or m == "\n" then
				local what = typed

				typed = ""
				paintinput()
				if what ~= "" then
					post(what)
				end
			elseif m == "\27" then
				if showlog then
					showlog = false
					paintbody(true)
				else
					break
				end
			elseif m == "\8" or m == "\127" then
				local n = utf8.len(typed)

				if n and n > 0 then
					typed = typed:sub(1,
					    utf8.offset(typed, n) - 1)
				end
				paintinput()
			elseif m == "\27[A" then
				scroll(-SCROLL)
			elseif m == "\27[B" then
				scroll(SCROLL)
			elseif m:byte(1) >= 0x20 and m:byte(1) ~= 0x7f then
				typed = typed .. m
				paintinput()
			end
		end
	end
	if relay then
		relay:close()
	end
end

thread.spawn(pointer)
thread.spawn(ui)
thread.run()
