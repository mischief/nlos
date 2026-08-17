-- nostrui: a nostr client on the panel.
--
--	enter            publish what is typed
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

local net = prog.net() or die("no network: /etc/dio.lua must say net = true")
local dns = prog.dns()
local rand = prog.rand()
local ptr = prog.mouse()

local KEYFILE = "/config/nostr.key"		-- an nsec, or hex
local RELAYFILE = "/config/nostr.relay"		-- one wss:// url
local RELAY = "wss://relay.damus.io"
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

local function paintbar()
	if not visible then
		return
	end

	local host = url:match("^wss?://([^/]+)") or url

	fill(0, 0, W, ROWH, 0x202028)
	text(0, 0, "[" .. host .. "]", FG, 0x202028)
	text((#host + 3) * FW, 0, status, DIM, 0x202028)
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

local function note(s)
	relaylog[#relaylog + 1] = plain(s):sub(1, COLS)
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

-- ---- keys ----

local key = N:readfile(KEYFILE)

if key then
	seckey = nostr.seckey(key)
	if seckey then
		pubkey = nostr.pubkey(seckey)
	end
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
local function show(ev)
	local who = nostr.npub(nostr.unhex(ev.pubkey)) or ev.pubkey

	say(who:sub(1, 12) .. ".." .. who:sub(-6), WHO)
	say(ev.content)
	say("")
end

-- where the time goes, reported at the end because guessing was wrong:
-- signatures are a fifth of it, and the relay and the panel are the
-- rest.
local function drain(t0)
	local shown, vms, first = 0, 0, nil
	local nms, sms = 0, 0

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

		if what == "event" then
			local v0 = sys.uptime_ms()
			local ok, why = nostr.verify(b)

			vms = vms + (sys.uptime_ms() - v0)
			if ok then
				local s0 = sys.uptime_ms()

				shown = shown + 1
				status = ("%d notes"):format(shown)
				paintbar()
				show(b)
				sms = sms + (sys.uptime_ms() - s0)
			else
				note("bad event: " .. tostring(why))
			end
		elseif what == "eose" then
			local all = sys.uptime_ms() - t0

			status = ("%d notes"):format(shown)
			paintbar()
			note(("%d notes in %d ms: %d verifying, %d the rest")
			    :format(shown, all, vms, all - vms))
			sys.log(("nostr: %d notes, %d ms: %d verify, " ..
			    "%d relay, %d draw, first %d ms")
			    :format(shown, all, vms, nms - vms, sms,
			    first or -1))
			return
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
	end
end

local function connect()
	if busy then
		return
	end
	busy = true
	status = "connecting"
	paintbar()

	thread.spawn(function()
		local c0 = sys.uptime_ms()
		local r, err = nostrrelay.connect(net, dns, url, rand)

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
		say("no key: put an nsec in " .. KEYFILE, WARN)
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
	say("posting as " .. (nostr.npub(pubkey) or "?"):sub(1, 20) .. "..", DIM)
else
	say("no key in " .. KEYFILE .. ", so this reads only.", DIM)
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
			if m == "\r" or m == "\n" then
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
