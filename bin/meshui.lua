-- meshui: the meshtastic network, on the panel.
--
--	enter sends, tab is the node list, up/down scroll, esc leaves.
--	/help lists the rest.

-- A view over task/meshsrv. dio lends it the mesh because its
-- /etc/dio.lua entry says mesh = true. Arrivals are pushed to a port
-- rather than polled for, so this does not race `mesh watch` for them.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local frame = require("frame")

local fb = prog.screen()
local srv = prog.mesh()

local function die(s)
	io.stderr:write("meshui: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no framebuffer on this machine")
end
if not srv then
	die("no mesh here; the tray entry needs mesh = true")
end

local mode = fb.mode()
local W, H = mode.w, mode.h
-- the panel's own format: drawing bgrx at a screen that wants r5g6b5
-- puts the wrong colors up rather than failing.
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local MINE, THEM, NOTE, WARN = 0x60a0e0, 0xd0d0d8, 0x80c090, 0xc06060

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
	-- string is briefly not utf8 at all. Cut bytes then.
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
-- lands. It takes one string, so the transcript is one -- and it says
-- which line a wrapped row came from, which is what keeps its colour.
local F = frame.new(COLS, rows)
local lines = {}		-- {text, color}, oldest first
local shownrow = {}
local typed = ""
local nodes = {}		-- what the service last told us
local shownodes = false
local unread = 0
local visible = true
local me, myname = "?", "lua-os"
local chan, quiet = nil, false

local function paintbar()
	if not visible then
		return
	end

	local n = 0

	for _ in pairs(nodes) do
		n = n + 1
	end

	local where = chan and
	    ("%s %.1f"):format(chan.name, chan.freq) or "no channel"

	-- what is waiting behind the node list, which is otherwise a
	-- message arriving on a screen that does not show messages
	local behind = unread > 0 and ("  %d new"):format(unread) or ""

	fill(0, 0, W, ROWH, 0x202028)
	text(0, 0, ("%s %s  %d node%s%s%s"):format(myname, where, n,
	    n == 1 and "" or "s", quiet and "  listening only" or "",
	    behind), quiet and WARN or DIM, 0x202028)
end

local function paintinput()
	if not visible then
		return
	end
	fill(0, INPUT, W, ROWH, 0x181820)

	local s = "> " .. typed
	local n = utf8.len(s)

	-- the tail, so a long line shows what is being typed rather than
	-- what was typed first. In codepoints, not bytes.
	if n and n > COLS then
		s = s:sub(utf8.offset(s, n - COLS + 1))
	end
	text(0, INPUT, s, quiet and DIM or FG, 0x181820)
end

local function paintnodes()
	local y = TOP

	text(0, y, "heard -- tab goes back", DIM)
	y = y + ROWH

	local list = {}

	for _, nd in pairs(nodes) do
		list[#list + 1] = nd
	end
	table.sort(list, function(a, b)
		return (a.heard or 0) > (b.heard or 0)
	end)

	if #list == 0 then
		text(0, y, "nobody yet", DIM)
		return
	end

	local now = sys.uptime_ms()

	for _, nd in ipairs(list) do
		if y + ROWH > INPUT then
			break
		end
		text(0, y, ("%-9s %-12s %4.0fdBm %3ds"):format(nd.id,
		    head(nd.long or nd.short or "", 12), nd.rssi or 0,
		    (now - (nd.heard or 0)) // 1000), FG)
		y = y + ROWH
	end
end

local function paintbody(all)
	if not visible then
		return
	end

	if shownodes or all then
		fill(0, TOP, W, INPUT - TOP, BG)
		shownrow = {}
	end

	if shownodes then
		paintnodes()
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
			text(0, y, s,
			    l and lines[l.line] and lines[l.line][2] or THEM)
		end
	end
	shownrow = seen
end

-- the transcript as the frame's one string. Rebuilt rather than
-- appended to: the frame wraps what it is given, and a bounded
-- scrollback drops from the front anyway.
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
	if shownodes then
		unread = unread + 1
		paintbar()
	end
	paintbody()
end

-- ---- the service ----

local reply = sys.newport("meshui.reply")
local right = sys.sendright(reply)

local function ask(m, ms)
	m.reply = { __right = right }
	if not sys.send(srv, m) then
		return nil
	end
	return thread.recvtimeout(reply, ms or 5000)
end

-- arrivals are pushed here, so two readers of the mesh do not divide
-- one inbox between them
local inport = sys.newport("meshui.mesh")

local function refresh()
	local r = ask({ op = "status" })
	local s = r and r.ok

	if s then
		me, myname = s.me, s.name
		chan, quiet = s.chan, s.quiet
	end

	local rn = ask({ op = "nodes" })

	if rn and rn.ok then
		nodes = {}
		for _, nd in ipairs(rn.ok) do
			nodes[nd.num or nd.id] = nd
		end
	end
	paintbar()
end

-- a name if the node has told us one, and its number if it has not
local function who(m)
	local nd = nodes[m.from] or {}

	return m.long or m.short or nd.long or nd.short or m.id
end

local function arrived(m)
	if type(m) ~= "table" or not m.id then
		return
	end

	-- what a node says about itself goes into the list whether or not
	-- it is worth a line of transcript
	local nd = nodes[m.from] or { num = m.from, id = m.id }

	nd.rssi, nd.snr, nd.heard = m.rssi, m.snr, m.at or sys.uptime_ms()
	if m.long or m.short then
		nd.long, nd.short = m.long or nd.long, m.short or nd.short
	end
	nodes[m.from] = nd

	if m.port == 1 then
		say(("%s: %s"):format(who(m), m.text or ""), THEM)
	elseif m.port == 4 then
		say(("* %s is %s"):format(m.id, who(m)), NOTE)
	elseif m.port == 3 and m.lat then
		say(("* %s at %.4f,%.4f"):format(who(m), m.lat, m.lon or 0),
		    NOTE)
	end
	paintbar()
end

-- ---- what is typed ----

local HELP = {
	"/announce   say who we are",
	"/nodes      the node list, as tab does",
	"/clear      forget the transcript",
	"esc leaves, up and down scroll",
}

local function docommand(s)
	local cmd = s:match("^/(%a+)")

	if cmd == "help" then
		for _, l in ipairs(HELP) do
			say(l, DIM)
		end
	elseif cmd == "announce" then
		local r = ask({ op = "announce" }, 40000)

		if r and r.ok then
			say("* announced", NOTE)
		else
			say("* not announced: " ..
			    tostring(r and r.err or "no answer"), WARN)
		end
		refresh()
	elseif cmd == "nodes" then
		shownodes = true
		paintbody(true)
	elseif cmd == "clear" then
		lines = {}
		retext()
		paintbody(true)
	else
		say("* no such command: " .. s, WARN)
	end
end

local function submit()
	local s = typed

	typed = ""
	paintinput()
	if s == "" then
		return
	end

	-- what you just did belongs on the screen you are looking at.
	-- Sending from the node list otherwise answers into a transcript
	-- that is not up, and reads as a key that did nothing.
	if shownodes then
		shownodes, unread = false, 0
		paintbar()
		paintbody(true)
	end

	if s:sub(1, 1) == "/" then
		return docommand(s)
	end

	local r = ask({ op = "send", text = s }, 40000)

	if r and r.ok then
		-- the radio does not hear itself, so what we said is put
		-- up here or it would leave no trace at all
		say(myname .. ": " .. s, MINE)
	else
		say("* not sent: " .. tostring(r and r.err or "no answer"),
		    WARN)
	end
end

-- ---- the loop ----

local function onwin(state)
	visible = state ~= "hidden"
	if visible then
		fill(0, 0, W, H, BG)
		paintbar()
		paintbody(true)
		paintinput()
	end
end

local ev = prog.events()

fill(0, 0, W, H, BG)
refresh()
paintbody(true)
paintinput()

if not ask({ op = "subscribe", port = { __right = sys.sendright(inport) } })
then
	say("* the mesh will not push arrivals here", WARN)
end

say(("mesh as %s (%s)"):format(myname, me), DIM)
if quiet then
	say("* this channel is somebody else's; nothing will go out", WARN)
end

-- built once and kept: alt neither keeps nor caches this, and rebuilding
-- it every trip round the loop is most of what an alt costs. The timer
-- is re-armed in place when it fires, which is the one case that moves.
local cases = {
	{ port = ev },
	{ port = inport },
	{ port = sys.timer(15000) },
}

while true do
	local which, m = thread.alt(cases)

	if which == 3 then
		refresh()
		if shownodes then
			paintbody(true)
		end
		cases[3].port = sys.timer(15000)
	elseif which == 2 then
		arrived(m)
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
				shownodes = not shownodes
				if not shownodes then
					unread = 0
				end
				paintbar()
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
	end
end
