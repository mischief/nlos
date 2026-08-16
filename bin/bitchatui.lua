-- bitchatui: the bitchat mesh, on the panel.
--
--	up/down    scroll back
--	tab        the peer list, and our fingerprint
--	enter      send what is typed
--	esc        leave

-- A view over lib/bitchat and lib/noise. dio lends it the adapter
-- because its /etc/dio.lua entry says ble = true.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local frame = require("frame")
local uuid = require("ble.uuid")
local att = require("ble.att")
local packet = require("bitchat.packet")
local session = require("bitchat.session")
local ed25519 = require("crypto.ed25519")
local x25519 = require("crypto.x25519")
local sha256 = require("crypto.sha256")

local N = prog.ns()
local fb = prog.screen()
local srv = prog.ble()

local function die(s)
	io.stderr:write("bitchatui: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no framebuffer on this machine")
end
if not srv then
	die("no bluetooth; the tray entry needs ble = true")
end

local mode = fb.mode()
local W, H = mode.w, mode.h
-- the panel's own format: drawing bgrx at a screen that wants r5g6b5
-- puts the wrong colors up rather than failing.
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local MINE, THEM, PRIV, WARN = 0x60a0e0, 0xd0d0d8, 0xc080e0, 0xc06060

local FW, FH = 6, 12
local ROWH = FH + 2
local TOP = ROWH			-- the bar
local INPUT = H - ROWH			-- the line being typed
local rows = math.floor((INPUT - TOP) / ROWH)
local COLS = W // FW

-- ---- drawing ----

-- the first n codepoints, which is not the first n bytes: cutting a
-- utf8 sequence in half draws a box where a character was.
local function head(s, n)
	local len = utf8.len(s)

	-- a sequence still being typed arrives a byte at a time, so the
	-- string is briefly not utf8 at all. Cut bytes then: it is one
	-- frame, and the alternative is drawing nothing.
	if not len then
		return #s > n and s:sub(1, n) or s
	end
	if len <= n then
		return s
	end

	local at = utf8.offset(s, n + 1)

	return at and s:sub(1, at - 1) or s
end

local function text(x, y, s, fg, bg)
	s = tostring(s or "")
	if s == "" then
		return
	end

	local room = (W - x) // FW

	if room < 1 then
		return
	end
	s = head(s, room)

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if not px then
		return
	end
	fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
end

local function fill(x, y, w, h, color)
	fb.fill({ x = x, y = y, w = w, h = h }, color, true)
end

-- ---- what is on the screen ----

-- lib/frame.lua holds the wrapping, the scroll and where a codepoint
-- lands. It takes one string, so the transcript is one -- and the colour
-- of a wrapped row is found from the byte offset the frame hands back.
local F = frame.new(COLS, rows)
local lines = {}		-- {text, color}, oldest first
local starts = {}		-- where each line begins in the frame's text
local shownrow = {}		-- what each row already shows
local typed = ""
local peers = {}		-- peer id -> {nick, noisekey, seen}
local sessions = {}		-- peer id -> a Noise session
local showpeers = false
local visible = true
local status = "starting"
-- the whole hash of our static key, which is what another client shows
-- for us and what two people compare to know nobody is between them.
local fingerprint = ""

local function paintbar()
	if not visible then
		return
	end

	local n = 0

	for _ in pairs(peers) do
		n = n + 1
	end
	fill(0, 0, W, ROWH, 0x202028)
	text(0, 0, string.format("%d peer%s  %s", n, n == 1 and "" or "s",
	    status), DIM, 0x202028)
end

local function paintinput()
	if not visible then
		return
	end
	fill(0, INPUT, W, ROWH, 0x181820)

	local s = "> " .. typed
	local n = utf8.len(s)

	-- the tail, so a long line shows what is being typed rather than
	-- what was typed first. In codepoints: cutting bytes would split
	-- a sequence and draw a box for the character it halved.
	if n and n > COLS then
		s = s:sub(utf8.offset(s, n - COLS + 1))
	end
	text(0, INPUT, s, FG, 0x181820)
end

-- which message a wrapped row came from, so it keeps its colour. The
-- frame hands back the byte offset of the row it drew, and the messages
-- are in offset order, so this is a search rather than a scan.
local function colorat(boff)
	local lo, hi, at = 1, #starts, 1

	while lo <= hi do
		local mid = (lo + hi) // 2

		if starts[mid] <= boff then
			at = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return lines[at] and lines[at][2] or THEM
end

local function paintbody(all)
	if not visible then
		return
	end

	if showpeers or all then
		fill(0, TOP, W, INPUT - TOP, BG)
		shownrow = {}
	end

	if showpeers then
		local y = TOP

		text(0, y, "fingerprint", DIM)
		y = y + ROWH
		for i = 1, #fingerprint, 20 do
			text(0, y, fingerprint:sub(i, i + 19), FG)
			y = y + ROWH
		end
		y = y + ROWH // 2
		text(0, y, "peers", DIM)
		y = y + ROWH
		for id, p in pairs(peers) do
			if y + ROWH > INPUT then
				break
			end
			text(0, y, (p.nick or "?") .. "  " .. id:sub(1, 8),
			    sessions[id] and PRIV or FG)
			y = y + ROWH
		end
		return
	end

	-- only the rows whose text changed: a message appends one line, so
	-- a repaint is one row rather than the whole body. A row costs
	-- 111ms on this panel.
	local seen = {}

	for i = 1, rows do
		local s, l = F:line(i)
		local y = TOP + (i - 1) * ROWH

		s = s or ""
		seen[i] = s
		if shownrow[i] ~= s then
			fill(0, y, W, ROWH, BG)
			text(0, y, s, l and colorat(l.boff) or THEM)
		end
	end
	shownrow = seen
end

-- the transcript as the frame's one string, and where each message
-- begins in it. Rebuilt rather than appended to: the frame wraps what
-- it is given, and a bounded scrollback drops from the front anyway.
local function retext()
	local parts = {}
	local off = 1

	starts = {}
	for i, l in ipairs(lines) do
		starts[i] = off
		parts[i] = l[1]
		off = off + #l[1] + 1		-- the newline between them
	end
	F:settext(table.concat(parts, "\n"))
end

local function atbottom()
	return F.top >= F:nlines() - F.rows
end

local function say(s, color)
	local stick = atbottom()

	lines[#lines + 1] = { s, color or THEM }
	-- a bounded scrollback: this is a handheld, and the text is built
	-- again whenever it changes.
	while #lines > 200 do
		table.remove(lines, 1)
	end
	retext()
	-- follow the end unless the reader has scrolled back, which is
	-- what makes a busy mesh readable rather than jumping.
	if stick then
		F:scroll(F:nlines())
	end
	paintbody()
end

-- ---- identity ----

local KEYFILE = "/config/bitchat_id"
local randbytes = prog.rand() or die("no entropy")

local function identity()
	local raw = N and N:readfile(KEYFILE)

	if raw and #raw == 32 then
		return raw
	end

	local seed = randbytes(32)

	if N then
		N:writefile(KEYFILE, seed)
	end
	return seed
end

local function derive(seed, label)
	return sha256.new():update(label):update(seed):final()
end

local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

local seed = identity()
local noisesec = derive(seed, "bitchat-noise-static")
local noisepub = x25519.scalarmult_base(noisesec)
local signsec = derive(seed, "bitchat-ed25519-signing")
local signpub = ed25519.publickey(signsec)
local myid = sha256.new():update(noisepub):final():sub(1, 8)

fingerprint = hex(sha256.new():update(noisepub):final()):upper()

local nick = (arg and arg[2]) or "tdeck"

-- ---- the radio ----

local SERVICE = uuid.parse("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
local CHAR = uuid.parse("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")

local function ask(m, ms)
	local reply = sys.newport("bitchatui.reply")
	local guard <close> = sys.owned(reply)

	m.reply = { __right = reply }
	sys.send(srv, m)

	local r = thread.recvtimeout(reply, ms or 5000)

	return r or { err = "no answer" }
end

local port = sys.newport("bitchatui.events")
local guard <close> = sys.owned(port)

ask({ op = "watch", port = { __right = port }, want = "all" })

local mine = ask({ op = "serve", service = SERVICE,
    port = { __right = port },
    chars = { { uuid = CHAR, props = 0x04 | 0x08 | 0x10 } } })

if mine.err then
	die(mine.err)
end

local mychar = mine.handles.chars[1].value
local mycccd = mine.handles.chars[1].cccd

-- a link from an earlier run subscribed to a service that no longer
-- exists, so a notification would go nowhere.
for _, l in ipairs((ask({ op = "status" }).links) or {}) do
	ask({ op = "disconnect", handle = l.handle })
end

ask({ op = "advertise", on = true, name = nick, service = SERVICE })
ask({ op = "scan", on = true })
status = "advertising"

local function now()
	local t = os.time()

	return t and math.floor(t) * 1000 or 0
end

local function signed(p)
	p.signature = ed25519.sign(signsec, packet.signinput(p))
	return packet.encode(p)
end

local function announce()
	return signed({ type = packet.ANNOUNCE, ttl = 3, timestamp = now(),
	    sender = myid,
	    payload = packet.encodeannounce({ nickname = nick,
		noisekey = noisepub, signkey = signpub }) })
end

local function send(b)
	local r = ask({ op = "notify", attr = mychar, value = b })

	return not (r.err or r.ok == false)
end

local function whois(id)
	local p = peers[hex(id)]

	return (p and p.nick) or hex(id):sub(1, 8)
end

-- ---- what arrives ----

local seen = {}

local function onhandshake(p)
	if p.recipient ~= myid then
		return
	end

	local id = hex(p.sender)
	local s = sessions[id]

	if #p.payload == session.INIT_SIZE and
	    (not s or not s:established()) then
		s = session.new(noisesec, randbytes, false)
		sessions[id] = s
	end
	if not s then
		return
	end

	local reply, err = s:handshake(p.payload)

	if err then
		sessions[id] = nil
		say("handshake with " .. whois(p.sender) .. " failed", WARN)
		return
	end
	if reply then
		send(packet.encode({ type = packet.NOISE_HANDSHAKE, ttl = 7,
		    timestamp = now(), sender = myid, recipient = p.sender,
		    payload = reply }))
	end
	if s:established() then
		say("* private session with " .. whois(p.sender), PRIV)
		paintbar()
	end
end

local function onencrypted(p)
	if p.recipient ~= myid then
		return
	end

	local s = sessions[hex(p.sender)]

	if not s or not s:established() then
		return
	end

	local kind, body = s:decrypt(p.payload)

	if kind == session.PRIVATE_MESSAGE then
		local m = session.decodeprivate(body)

		if m then
			say("[" .. whois(p.sender) .. "] " .. m.content, PRIV)
		end
	end
end

local function onpacket(b)
	local p = packet.decode(b)

	if not p or p.sender == myid then
		return
	end

	local key = hex(p.sender) .. tostring(p.timestamp)

	if seen[key] then
		return
	end
	seen[key] = true

	if p.type == packet.ANNOUNCE then
		local a = packet.decodeannounce(p.payload)
		local id = hex(p.sender)

		if not peers[id] then
			say("* " .. (a.nickname or "?") .. " is here", DIM)
			paintbar()
		end
		peers[id] = { nick = a.nickname, noisekey = a.noisekey }
	elseif p.type == packet.MESSAGE then
		say("<" .. whois(p.sender) .. "> " .. p.payload)
	elseif p.type == packet.LEAVE then
		peers[hex(p.sender)] = nil
		paintbar()
	elseif p.type == packet.NOISE_HANDSHAKE then
		onhandshake(p)
	elseif p.type == packet.NOISE_ENCRYPTED then
		onencrypted(p)
	end
end

-- ---- sending ----

local function submit()
	if typed == "" then
		return
	end

	-- the text alone: a reader takes the name from our announce, and
	-- derives an id from what it already has.
	if send(signed({ type = packet.MESSAGE, ttl = 7, timestamp = now(),
	    sender = myid, payload = typed })) then
		say("<" .. nick .. "> " .. typed, MINE)
	else
		say("not sent: nobody is listening", WARN)
	end
	typed = ""
	paintinput()
end

-- ---- the loop ----

local ev = prog.events()

local function onwin(state)
	visible = state ~= "hidden"
	if visible then
		fill(0, 0, W, H, BG)
		paintbar()
		paintbody(true)
		paintinput()
	end
end

fill(0, 0, W, H, BG)
paintbar()
paintbody(true)
paintinput()
say("bitchat as " .. nick, DIM)
-- one now, since the timer below does not fire for ten seconds.
send(announce())

-- built once and kept: alt neither keeps nor caches this, and rebuilding
-- it every trip round the loop is most of what an alt costs. The timer
-- is re-armed in place when it fires, which is the one case that moves.
local cases = {
	{ port = ev },
	{ port = port },
	{ port = sys.timer(10000) },
}

while true do
	local which, m = thread.alt(cases)

	if which == 3 then
		-- a peer that subscribed before we asked would otherwise
		-- never hear one.
		send(announce())
		cases[3].port = sys.timer(10000)
	elseif which == 1 and type(m) == "string" then
		if not mouse.parse(m) then
			if m == "\r" or m == "\n" then
				submit()
			elseif m == "\27" then
				break
			elseif m == "\8" or m == "\127" then
				typed = typed:sub(1, #typed - 1)
				paintinput()
			elseif m == "\t" then
				showpeers = not showpeers
				paintbody(true)
			elseif m == "\27[A" then
				F:scroll(-1)
				paintbody()
			elseif m == "\27[B" then
				F:scroll(1)
				paintbody()
			elseif m:byte(1) >= 0x20 and m:byte(1) ~= 0x7f then
				-- a whole character, which is one to four
				-- bytes: what arrives is a keystroke, not a
				-- byte of one.
				typed = typed .. m
				paintinput()
			end
		end
	elseif which == 1 and type(m) == "table" and m.t == "win" then
		onwin(m.state)
	elseif which == 2 and type(m) == "table" then
		if m.kind == "write" and m.attr == mycccd then
			send(announce())
		elseif m.kind == "write" or m.kind == "notify" then
			onpacket(m.value or "")
		elseif m.kind == "link" then
			status = m.up and "linked" or "advertising"
			paintbar()
		end
	end
end

ask({ op = "scan", on = false })
ask({ op = "advertise", on = false })
