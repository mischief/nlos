-- dio: a window system with one window.
--
-- The panel and the keyboard, as the machine's own interface: started
-- from /etc/services.lua the way task/fbterm.lua is, and in its place.
-- A launcher tray down the left, and the app in front filling everything
-- right of it. Several apps run at once and one is on the glass.
-- What the tray holds is /etc/dio.lua.
--
-- The terminal is one of those apps, so a prompt is a thing you switch
-- to rather than the thing everything else is launched from. It starts
-- at boot, so a board still comes up at a shell.
--
-- Spawned with a message carrying its rights:
--	{ fb = {__right=}, kbd = {__right=}, cons = {__right=},
--	  tcp = {__right=} }
--
-- The serial console is for saying what went wrong, and nothing else.
-- A window system that reported its own faults through the console on
-- the glass would draw them over the window it was reporting about --
-- lib/fbcons.lua writes where its grid says, and knows nothing of a
-- tray.
--
-- No overlap, ever. That is what makes this small: overlapping windows
-- force a layer stack and clipped drawing, and one visible app means a
-- rectangle and an offset instead.
--
-- ---- dio proxies, and does not lend ----
--
-- It holds the framebuffer and serves the same protocol on a port of
-- its own. An app is handed that port and asks it for the mode, so it
-- is told the app area's size and believes it: bin/scribble.lua runs
-- here unchanged, and so does anything else written for the whole
-- screen.
--
-- Handing the focused app the framebuffer right instead, and taking it
-- back on a switch, cannot be done. Rights here are copied, never
-- revoked, so an app given the screen keeps it, and one drawing over
-- the foreground could only be stopped by killing it.
--
-- The mouse goes the same way. dio opens /dev/mouse, which is
-- exclusive, and serves an app its own /dev/mouse with the coordinates
-- moved into app space -- so a tray touch never reaches the app,
-- because it never leaves dio.
--
-- ---- an app dies with dio ----
--
-- Both of an app's capabilities are ports dio receives on, so when dio
-- goes away its app is left holding rights nothing answers: its next
-- mouse read fails and it exits. Nothing is left drawing on a screen it
-- no longer has.
--
-- The other side of that: dio is the panel, so a dio that dies takes
-- the panel with it until the machine restarts. The serial line is the
-- way back in, which is why it carries diagnostics and nothing else.
--
-- ---- the tray ----
--
-- A launcher pinned at the top, and below it one button per RUNNING
-- app. What is in /etc/dio.lua is a catalogue of what may be started
-- rather than a set of slots, so an entry may be started more than
-- once: two terminals are two instances of one entry, with windows and
-- keyboards of their own.
--
-- A tap brings an instance to the front. A second tap on the same
-- button within half a second stops it: closing has to be there, since
-- an app has a screen and a pointer and no keyboard and bin/smiley.lua
-- ends on a keystroke -- and it has to be the rarer gesture, since
-- switching is the one done constantly.
--
-- The wheel over the tray scrolls the list -- the trackball rolled
-- vertically, which is this machine's scroll and what lib/mousefs.lua
-- already reports as buttons 8 and 16. So how many apps may run is a
-- question about memory rather than about how tall the screen is. The
-- launcher does not scroll with them: it is the way to start anything,
-- so it stays where it can be reached.
--
-- ---- several apps, one window ----
--
-- Every app keeps running whether or not it is in front. What being in
-- front buys is the glass and the pointer: a draw from any other app is
-- dropped here, and the pointer's records go to one /dev/mouse.
--
-- Dropped rather than refused. An app behind has nothing to fix, and an
-- error per drawing call would make every program handle a window
-- system it otherwise need not know about. It is told to draw itself
-- again through /dev/wctl when it comes back.
--
-- So there are no saved pixels anywhere: coming to the front is a
-- cleared rectangle and one line on a file. An app that cannot redraw
-- itself comes back empty, which is the price of a window system on a
-- board with 4MB.

local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")
local caps = require("caps")
local mousefs = require("mousefs")
local wctlfs = require("wctlfs")
local proc = require("proc")
local srv = require("srv")

-- started either way: as a service, lib/svc.lua hands the capabilities
-- to the chunk as its argument; started by hand from the repl, they
-- arrive in a message.
local job = ... or thread.recv(sys.SELF)
local fb = job.fb and job.fb.__right
local kbd = job.kbd and job.kbd.__right
local cons = job.cons and job.cons.__right
local tcp = job.tcp and job.tcp.__right
local power = job.power and job.power.__right
local ip = job.ip and job.ip.__right

local function say(s)
	if cons then
		sys.send(cons, { op = "write", data = "dio: " .. s .. "\n" })
	end
end

-- the namespace this proc was given, which is where /etc/dio.lua, the
-- programs and /dev/mouse are. Described from here rather than taken
-- from the message: proc.spawn adopts it before this chunk runs, so
-- what arrives in the message is the capability table alone.
local N = require("ns").current()

if not fb then
	say("no framebuffer")
	return
end
if not N then
	say("no namespace")
	return
end

local screen = caps.fb(fb)

-- ---- the framebuffer, asked directly ----
--
-- caps.fb is the wrapper every client uses, this one included; what it
-- has no op for is the cursor, which is the machine's rather than an
-- app's. So the raw request/reply is here as well.

local function ask(m)
	local rp, send = thread.replyport()

	m.reply = { __right = send }
	sys.send(fb, m)

	local r = thread.recv(rp)

	if type(r) ~= "table" then
		return nil, "no answer from the framebuffer"
	end
	if r.err then
		return nil, r.err
	end
	return r.ok
end

local mode = ask({ op = "mode" })

if not mode then
	say("cannot read the screen mode")
	return
end

-- ---- the tray ----

local conf = { width = 28, apps = {} }
local csrc = N:readfile("/etc/dio.lua")

if csrc then
	local chunk, cerr = load(csrc, "=/etc/dio.lua")
	local ok, res = false, cerr

	if chunk then
		ok, res = pcall(chunk)
	end
	if ok and type(res) == "table" then
		conf.width = tonumber(res.width) or conf.width
		conf.apps = res.apps or {}
	else
		say("/etc/dio.lua: " .. tostring(res))
	end
end

local TRAY = conf.width
local APPX, APPY = TRAY, 0
local APPW, APPH = mode.w - TRAY, mode.h

local TRAYBG = 0x202830
local EDGE = 0x506070
local RUNNING = 0xffffff

-- one button per instance, stacked from the top. Square, so the glyph
-- sits in the middle of it whatever the tray's width is.
local BUTTON = TRAY - 6
local GAP = 4
local PITCH = BUTTON + GAP

-- the launcher is pinned above them and does not scroll: it is how an
-- app is started, so it must be reachable whatever the list below has
-- been scrolled to.
local PLUS = { x = 3, y = GAP, w = BUTTON, h = BUTTON }
local PLUSCOLOR = 0x404c5c
local LISTY = GAP + BUTTON + GAP + 3	-- below the plus and its rule

-- how many instances the tray shows at once, and where the list has
-- been scrolled to. Whole buttons rather than pixels: a button is
-- either drawn or it is not, which is what keeps this from needing to
-- clip one against the bottom of the screen.
local VISIBLE = (mode.h - LISTY) // PITCH
local trayoff = 0

-- the apps that are up, keyed by an id of their own, in the order they
-- were started. A running app is no longer the same thing as an entry
-- in the config: several may come from one entry, and the config is a
-- catalogue of what CAN be started rather than a set of slots.
--
-- Declared here because the tray is drawn from them and filled in
-- further down, where the windows are made.
local catalog = conf.apps
local apps = {}		-- id -> instance
local order = {}	-- ids, top to bottom in the tray
local front = nil	-- the id on the glass
local nextid = 1

-- what stops another app being started.
--
-- The count is the backstop; the memory is the real answer, because
-- what a program costs is not something a number written here can know.
-- Measured on a T-Deck, a terminal and its shell take about 32KB of
-- INTERNAL memory -- not the lua heap, which is in PSRAM and was never
-- the thing that ran out. Eight of them left 12KB of 355KB free, one
-- proc dead and not enough room to draw.
--
-- So the floor is three more instances' worth, kept clear: what is left
-- has to run the programs typed into those terminals, not merely hold
-- the terminals.
local MAXAPPS = 6
local APPMEM = 32 * 1024
local MEMFLOOR = 3 * APPMEM

-- what the machine has left, or nil where it cannot say. A platform
-- with no meminfo answers 0, and then the count above is the whole of
-- the limit.
local function memleft()
	local ok, st = pcall(sys.stats)
	local avail = ok and type(st) == "table" and st.memavail

	if type(avail) ~= "number" or avail <= 0 then
		return nil
	end
	return avail
end

local function slotof(id)
	for k, v in ipairs(order) do
		if v == id then
			return k
		end
	end
	return nil
end

-- the rectangle for the k'th instance in the list, or nil where the
-- scroll has it off the screen.
local function slotrect(k)
	local at = k - trayoff

	if at < 1 or at > VISIBLE then
		return nil
	end
	return { x = 3, y = LISTY + (at - 1) * PITCH, w = BUTTON, h = BUTTON }
end

local function inrect(r, x, y)
	return r and x >= r.x and x < r.x + r.w and
	    y >= r.y and y < r.y + r.h
end

-- what a point in the tray is on: "plus", an instance id, or nil for
-- the space between.
local function buttonat(x, y)
	if inrect(PLUS, x, y) then
		return "plus"
	end
	for k, id in ipairs(order) do
		if inrect(slotrect(k), x, y) then
			return id
		end
	end
	return nil
end

-- the scroll, clamped to what there is to show. Returns true if it
-- moved, so a drag redraws only when something changed.
local function scrollto(n)
	local most = #order - VISIBLE

	if most < 0 then
		most = 0
	end
	if n < 0 then
		n = 0
	elseif n > most then
		n = most
	end
	if n == trayoff then
		return false
	end
	trayoff = n
	return true
end

-- every button in the list is a running app, so there is nothing to say
-- about whether it is running. What is left to mark is which one is on
-- the glass, and that is the border.

-- one button: a filled square, a border saying whether it is in front,
-- and a glyph in the middle.
local function drawface(r, color, label, edge)
	screen.fill(r, color)
	screen.fill({ x = r.x - 1, y = r.y - 1, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y + r.h, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y - 1, w = 1, h = r.h + 2 }, edge)
	screen.fill({ x = r.x + r.w, y = r.y - 1, w = 1, h = r.h + 2 }, edge)

	local pix, gw, gh = font.render(label:sub(1, 1), 0x000000, color)

	if gw > 0 and gw <= r.w and gh <= r.h then
		screen.load({ x = r.x + (r.w - gw) // 2,
		    y = r.y + (r.h - gh) // 2, w = gw, h = gh }, pix)
	end
end

local function drawplus()
	drawface(PLUS, PLUSCOLOR, "+", TRAYBG)
	-- a rule under it, so the launcher reads as a fixture rather than
	-- as the first of the list that scrolls beneath it.
	screen.fill({ x = 3, y = LISTY - 3, w = BUTTON, h = 1 }, EDGE)
end

-- an instance's button, or nothing where the scroll has it off screen.
local function drawslot(k)
	local r = slotrect(k)

	if not r then
		return
	end

	local a = apps[order[k]]
	local e = a and catalog[a.entry]

	drawface(r, (e and e.color) or 0x808080,
	    (e and (e.label or e.name)) or "?",
	    (front == order[k]) and RUNNING or TRAYBG)
end

local function drawbutton(id)
	local k = slotof(id)

	if k then
		drawslot(k)
	end
end

-- a mark at the top or the bottom of the list where there is more of it
-- in that direction: a tray that scrolls has to say that it does, or
-- the apps out of sight are apps you have lost.
local function drawmore()
	local up = (trayoff > 0) and RUNNING or TRAYBG
	local down = (#order - trayoff > VISIBLE) and RUNNING or TRAYBG

	screen.fill({ x = 3 + BUTTON // 2 - 3, y = LISTY - 2, w = 6, h = 1 },
	    up)
	screen.fill({ x = 3 + BUTTON // 2 - 3, y = LISTY + VISIBLE * PITCH - 2,
	    w = 6, h = 1 }, down)
end

local function drawlist()
	-- the band the instances live in, cleared first: a scroll moves
	-- every button in it and the one that was at the bottom has to
	-- stop being drawn there.
	screen.fill({ x = 0, y = LISTY - 1, w = TRAY - 1,
	    h = mode.h - LISTY + 1 }, TRAYBG)
	for k = 1, #order do
		drawslot(k)
	end
	drawmore()
end

local function drawtray()
	screen.fill({ x = 0, y = 0, w = TRAY - 1, h = mode.h }, TRAYBG)
	screen.fill({ x = TRAY - 1, y = 0, w = 1, h = mode.h }, EDGE)
	drawplus()
	drawlist()
end

local function clearapp()
	screen.fill({ x = APPX, y = APPY, w = APPW, h = APPH }, 0x000000, true)
end

-- ---- the app's screen ----
--
-- One rectangle, and every coordinate a client sends is relative to its
-- corner.
--
-- Rejected rather than clipped when it does not fit. A partly-clipped
-- fill would be easy and a partly-clipped load would not -- the pixels
-- would have to be re-cut to match -- and a proxy that silently drew
-- less than it was asked to is worse than one that says no. A client
-- that asked for the mode knows the size.
local function place(r)
	if type(r) ~= "table" then
		return nil, "no rectangle"
	end

	local x, y = r.x or 0, r.y or 0
	local w, h = r.w or 0, r.h or 0

	if w < 0 or h < 0 or x < 0 or y < 0 or
	    x + w > APPW or y + h > APPH then
		return nil, "outside the window"
	end
	return { x = x + APPX, y = y + APPY, w = w, h = h }
end

-- forward a translated message. A client that asked for an answer gets
-- one from the framebuffer; a client that did not is not made to wait
-- for a round trip it declined -- which is most of what an app sends,
-- since caps.fb's fill and load are fire-and-forget by default.
local function forward(m, wait)
	if wait then
		return ask(m)
	end

	local ok, err = caps.sendwait(fb, m)

	if not ok then
		return nil, err
	end
	return true
end

local ops = {}

-- the app area's size, in place of the screen's. An app that asks what
-- it has is answered with what it has.
function ops.mode()
	return { n = mode.n, w = APPW, h = APPH, format = mode.format }
end

function ops.modes()
	return { ops.mode() }
end

-- refused: the mode belongs to the machine, and an app that could
-- change it would change it for whatever else is running.
function ops.setmode()
	return nil, "the mode is not an app's to set"
end

local function rectop(op)
	return function(m, wait)
		local r, err = place(m.r)

		if not r then
			return nil, err
		end
		return forward({ op = op, r = r, color = m.color,
		    data = m.data }, wait)
	end
end

ops.fill = rectop("fill")
ops.load = rectop("load")

function ops.unload(m)
	local r, err = place(m.r)

	if not r then
		return nil, err
	end
	-- always waits: the pixels are the answer.
	return ask({ op = "unload", r = r })
end

function ops.scroll(m, wait)
	local r, err = place(m.r)

	if not r then
		return nil, err
	end

	local to = m.to or {}
	local dst, derr = place({ x = to.x or 0, y = to.y or 0,
	    w = m.r.w, h = m.r.h })

	if not dst then
		return nil, derr
	end
	return forward({ op = "scroll", r = r, to = { x = dst.x, y = dst.y } },
	    wait)
end

-- the cursor is the machine's, not an app's: it is drawn over whatever
-- is on the glass, tray included, and it follows the finger rather than
-- anything a client asked for. Passed through in screen coordinates.
function ops.cursor(m)
	return forward({ op = "cursor", x = m.x, y = m.y, on = m.on }, false)
end

-- ---- one window each, and one of them in front ----
--
-- Every app gets its own framebuffer port, its own /dev/mouse and its
-- own /dev/wctl. A port carries no sender identity, so a shared port
-- could not tell whose draw had arrived -- and knowing that is the
-- whole of what focus means here.
--
-- an instance is:
--	{ id, entry, name, pid, fbrecv, fbport, mouse, wctl, mport,
--	  wport, kind }
-- what is dropped when an app is not in front. mode, modes and setmode
-- are answers rather than marks on the glass, and an app asks for them
-- whenever it likes.
local DRAWS = { fill = true, load = true, unload = true, scroll = true,
    cursor = true }

-- Started once the app it serves exists, and not before.
--
-- srv.serve gives up when its port hangs up, and sys.hungup is
-- sole_holder: it is true while THIS proc holds every right to the
-- port. Between making an app's ports and spawning the app, dio holds
-- them all -- so a serve thread that runs in that window sees a port
-- nobody is left to talk on and returns, and the app's first walk of
-- /dev/wctl then waits for an answer that will never come.
--
-- Nothing is lost by starting late: a message sent before the thread
-- is running waits on the port like any other.
local function serveapp(a)

	thread.spawn(function()
		while true do
			local m = thread.recv(a.fbrecv)

			if type(m) == "table" then
				local fn = ops[m.op]
				local reply = m.reply and m.reply.__right
				local ok, err

				if not fn then
					err = "no such op: " .. tostring(m.op)
				elseif front ~= a.id and DRAWS[m.op] then
					-- dropped, not refused: an app that
					-- is not in front has nothing to
					-- fix, and telling it so would turn
					-- a switch into an error every
					-- program had to handle. It is told
					-- to draw again through /dev/wctl
					-- when it comes back.
					ok = true
				else
					ok, err = fn(m, reply ~= nil)
				end
				if reply then
					sys.send(reply, ok ~= nil and
					    { ok = ok } or
					    { err = err or "failed" })
					sys.close(reply)
				end
			end
		end
	end)
	thread.spawn(function()
		srv.serve(a.mouse.backend, a.mrecv)
	end)
	thread.spawn(function()
		srv.serve(a.wctl.backend, a.wrecv)
	end)
end

-- the namespace an app gets: dio's own, with this app's mouse and wctl
-- in front of the machine's /dev. Union order is list order, and a walk
-- that fails in one mount falls through to the next -- so wctl resolves
-- in the first, mouse in the second, and everything else in the
-- machine's.
local function appns(a)
	local desc = N:describe()

	table.insert(desc, 1, { prefix = "/dev", kind = "mnt",
	    args = { port = { __right = a.mport } } })
	table.insert(desc, 1, { prefix = "/dev", kind = "mnt",
	    args = { port = { __right = a.wport } } })
	return desc
end

-- a name for this instance, unique among the ones running: the second
-- terminal is term(2). Two windows are opened to look at two things,
-- and ps naming them both `term` would undo half of that.
local function instname(entry, self)
	local base = entry.name or "app"
	local n = 0

	-- everything already running from this entry, the one being named
	-- excluded: it is in the table by now, and counting it would make
	-- the first terminal term(2).
	for id, a in pairs(apps) do
		if a.entry == entry.idx and id ~= self then
			n = n + 1
		end
	end
	if n == 0 then
		return base
	end
	return ("%s(%d)"):format(base, n + 1)
end

-- make an app's windows before it is spawned, since what it is handed
-- is rights to them.
local function newapp(entryidx, kind)
	local fbrecv = sys.newport()
	local mrecv = sys.newport()
	local wrecv = sys.newport()
	-- a keyboard port per app, not one shared: a key belongs to
	-- whichever terminal is in front, and a port handed to two of them
	-- would give it to whichever asked first.
	local keys = sys.newport()
	local a = {
		id = nextid,
		entry = entryidx,
		kind = kind,
		fbrecv = fbrecv, fbport = sys.sendright(fbrecv),
		mrecv = mrecv, mport = sys.sendright(mrecv),
		wrecv = wrecv, wport = sys.sendright(wrecv),
		keys = keys, keysend = sys.sendright(keys),
		mouse = mousefs.new(),
		-- starts hidden and is shown by the switch below, so an app
		-- reads one "redraw" rather than a state and then an event
		-- saying the same thing
		wctl = wctlfs.new(false),
	}

	nextid = nextid + 1
	apps[a.id] = a
	order[#order + 1] = a.id
	return a
end

-- an instance and everything the tray knows about it, gone.
local function forget(id)
	local k = slotof(id)

	apps[id] = nil
	if k then
		table.remove(order, k)
	end
	-- the list is shorter, so the scroll may now be past its end
	scrollto(trayoff)
end

-- ---- a terminal in the window ----
--
-- task/fbterm.lua is the console stack -- glyphs through lib/fbcons.lua,
-- tty logic in lib/console.lua, a shell above it -- and it takes a
-- framebuffer and a keyboard port. Handed dio's framebuffer it draws in
-- the app area and asks it how big the screen is, so the grid is the
-- window's. Nothing in it knows about dio.
--
-- Keystrokes are forwarded rather than handed over, for the reason the
-- framebuffer is. Giving the app the keyboard right would work exactly
-- once: a right is copied and never revoked, so an app that has had the
-- keyboard keeps reading it after it stops being the one in front.
--
-- One pump for the life of this proc, parked on the port, delivering to
-- whichever terminal is in front. A key that arrives with no terminal
-- there is dropped, which is what "nothing is listening" means -- the
-- pointer, not the keyboard, is how an app is reached.
local wantkeys = false

if kbd then
	thread.spawn(function()
		while true do
			local c = thread.recv(kbd)
			local a = front and apps[front]

			if wantkeys and a and type(c) == "string" and
			    c ~= "" then
				sys.send(a.keysend, c)
			end
		end
	end)
end

local function startterm(a, entry, desc)
	local src, serr = N:readfile(entry.cmd)

	if not src then
		return nil, tostring(serr)
	end

	if not kbd then
		return nil, "no keyboard on this machine"
	end

	local pid, h = proc.spawn(src, { name = a.name, ns = desc })

	if not pid then
		return nil, "spawn failed"
	end

	sys.send(h, {
		fb = { __right = a.fbport },
		kbd = { __right = a.keys },
		-- the serial line, for what the terminal cannot report
		-- about itself. Its own output goes to the glass.
		cons = cons and { __right = cons } or nil,
		tcp = tcp and { __right = tcp } or nil,
		-- and power, which is what bin/reboot.lua spends. The panel
		-- is a local terminal: it holds what the serial console
		-- holds, and a session over the network does not.
		power = power and { __right = power } or nil,
		-- the ip task, which is also the udp server: bin/host.lua
		-- and bin/date.lua ask a server one question each.
		ip = ip and { __right = ip } or nil,
	})
	sys.close(h)
	return pid
end

-- ---- switching ----
--
-- The app in front owns the glass and the pointer; every other one
-- keeps running with its draws dropped. Coming to the front is an area
-- cleared and a "redraw" on /dev/wctl, so an app paints from its own
-- state onto a known-empty rectangle -- which is what buys a machine
-- this size a window system with no saved pixels anywhere.
local function focus(id)
	if front == id then
		return
	end

	local was = front

	front = id
	if was and apps[was] then
		apps[was].wctl.show(false)
	end
	clearapp()
	if id and apps[id] then
		apps[id].wctl.show(true)
	end
	-- keys follow the front, and only a terminal reads them
	wantkeys = id ~= nil and apps[id] ~= nil and apps[id].kind == "term"
	if was then
		drawbutton(was)
	end
	if id then
		drawbutton(id)
	end
end

local function start(i)
	local entry = catalog[i]

	if not entry then
		return nil, "no such entry"
	end
	-- asked before the instance is made, so the one being started is
	-- not counted against itself.
	if #order >= MAXAPPS then
		return nil, ("%d apps is all this machine has room for")
		    :format(MAXAPPS)
	end

	local left = memleft()

	if left and left < MEMFLOOR + APPMEM then
		return nil, ("%dK free is not enough to start another")
		    :format(left // 1024)
	end

	entry.idx = i
	local a = newapp(i, entry.kind)

	a.name = instname(entry, a.id)

	local desc = appns(a)
	local pid, err

	if entry.kind == "term" then
		pid, err = startterm(a, entry, desc)
	else
		local h

		pid, h = proc.spawn('require("prog").main()',
		    { name = a.name, ns = desc })
		if pid then
			-- a program's own output goes to the serial line
			-- rather than to the console on the glass, which
			-- draws where its grid says and would write over
			-- the window the program is drawing in.
			sys.send(h, {
				path = entry.cmd,
				name = a.name,
				args = { entry.name },
				env = { PATH = "/bin", HOME = "/" },
				cwd = "/",
				nsdesc = desc,
				fb = { __right = a.fbport },
				stdout = cons and { __right = cons } or nil,
				stderr = cons and { __right = cons } or nil,
			})
			sys.close(h)
		else
			err = "spawn failed"
		end
	end

	if not pid then
		forget(a.id)
		return nil, err
	end
	a.pid = pid
	-- the app holds rights to its ports now, so the serves may
	-- start: see serveapp for what starting them sooner does.
	serveapp(a)
	sys.monitor(pid)
	-- the list grew, so every button below the new one moved
	drawlist()
	focus(a.id)
	return a.id
end

-- what the launcher does. Another of the entry marked `boot`, which is
-- the terminal on every machine that has one: what a second window is
-- wanted for is nearly always a second prompt.
local function launch()
	local pick

	for i, e in ipairs(catalog) do
		if e.boot then
			pick = i
			break
		end
	end
	pick = pick or 1

	local id, serr = start(pick)

	if not id then
		say(((catalog[pick] and catalog[pick].name) or "app") ..
		    ": " .. tostring(serr))
		-- and on the glass, because the serial line is not where
		-- the person who touched the button is looking. The
		-- launcher goes red for a moment: what was refused is
		-- obvious, and the reason is on the console for whoever
		-- wants it.
		thread.spawn(function()
			drawface(PLUS, 0xcc0000, "+", TRAYBG)
			thread.sleep(700)
			drawplus()
		end)
	end
end

-- ---- the pointer ----
--
-- One reader of the machine's mouse, and it is this proc. A record in
-- the tray is a touch on a button; anything else is moved into app
-- space and posted to the app's own file.

local mouse, merr = N:open("/dev/mouse", "r")

if not mouse then
	say("no /dev/mouse: " .. tostring(merr))
	return
end

drawtray()
clearapp()

local BUT1 = 1

-- A run of unreadable records is a broken pointer rather than a stray
-- one. Losing the pointer is losing the tray, which is the only way to
-- start or stop anything, so it is said out loud rather than left as a
-- window system that stops answering.
local BADMAX = 8

-- how close two taps on one button have to be to mean "close it". Long
-- enough for a finger on a panel, short enough that switching to an app
-- and back does not stop it by accident.
local DOUBLE = 500
local lasttap, lastms = nil, 0

-- the wheel, as lib/mousefs.lua reports it: 8 up, 16 down, one click
-- per record. On the T-Deck that is the trackball rolled vertically,
-- which is the machine's scroll and is already what a list scrolls
-- with -- so the tray uses it rather than a gesture of its own.
local WHEELUP = 8
local WHEELDOWN = 16

thread.spawn(function()
	local down = false
	local bad = 0

	while true do
		local rec, rerr = mouse:read(49)

		if not rec then
			say("mouse: " .. tostring(rerr))
			break
		end

		local x, y, b = mousefs.parse(rec)

		if not x then
			bad = bad + 1
			if bad == 1 then
				say(("mouse: not a record: %d bytes, %q")
				    :format(#rec, rec:sub(1, 24)))
			end
			if bad >= BADMAX then
				say(("mouse: %d bad records; the tray is "
				    .. "no longer answering"):format(bad))
				break
			end
		else
			bad = 0
			local pressed = (b & BUT1) ~= 0

			if x < TRAY then
				if (b & (WHEELUP | WHEELDOWN)) ~= 0 then
					-- the wheel over the tray scrolls
					-- the list, and never starts or
					-- stops anything: a roll is not a
					-- press.
					local by = ((b & WHEELDOWN) ~= 0)
					    and 1 or -1

					if scrollto(trayoff + by) then
						drawlist()
					end
				elseif pressed and not down then
					-- the press edge, not the state: a
					-- finger held on a button must act
					-- once, and a drag out of the tray
					-- must not act again.
					local hit = buttonat(x, y)
					local now = sys.uptime_ms()
					local twice = hit and hit == lasttap and
					    now - lastms < DOUBLE

					lasttap, lastms = hit, now
					if hit == "plus" then
						launch()
					elseif hit and apps[hit] and twice then
						-- twice on a running app
						-- stops it. An app is given
						-- a screen and a pointer and
						-- no keyboard, so a program
						-- that ends on a keystroke
						-- has no other way out --
						-- and once must stay
						-- reserved for switching,
						-- which is the thing done
						-- constantly.
						--
						-- Marked as asked-for, so
						-- what follows is reported
						-- as an app ending rather
						-- than as an app dying.
						apps[hit].stopped = true
						pcall(sys.kill, apps[hit].pid)
					elseif hit and apps[hit] then
						-- running, behind: bring it
						-- forward. It keeps running
						-- either way -- what changes
						-- is whose draws reach the
						-- glass.
						focus(hit)
					end
				end
			elseif front and apps[front] then
				-- the pointer belongs to the app in front,
				-- and to nothing else: an app behind sees no
				-- part of a stroke it is not in.
				apps[front].mouse.post(
				    mousefs.format(x - APPX, y - APPY, b))
			end
			down = pressed
		end
	end
end)

-- which instance a pid belongs to, since an exit arrives as a pid
local function appof(pid)
	for id, a in pairs(apps) do
		if a.pid == pid then
			return id
		end
	end
	return nil
end

-- ---- what is left of this thread ----
--
-- The exits. An app that ends gives up its windows, and the front goes
-- to nothing rather than to a guess: with no ordering worth the name,
-- picking a successor would be inventing one.
thread.spawn(function()
	while true do
		local m = thread.recv(sys.SELF)
		local id = type(m) == "table" and m.exit and appof(m.exit)

		if id then
			local a = apps[id]
			local e = catalog[a.entry]

			forget(id)
			if front == id then
				front = nil
				wantkeys = false
				clearapp()
			end
			-- a proc killed on purpose is held as a corpse like
			-- any other, and nothing is going to inspect this
			-- one: the person who tapped the button knows why it
			-- stopped, and a corpse holds the whole working set
			-- until something reaps it.
			if a.stopped then
				pcall(sys.reap, m.exit)
			end
			-- the list closed up over it, so every button below
			-- where it was has moved
			drawlist()
			if not m.normal and not a.stopped then
				say(tostring(a.name or (e and e.name)) ..
				    ": " .. tostring(m.reason))
			end
		end
	end
end)

-- ---- what the machine comes up in ----
--
-- One entry may say boot = true, and it is started before anything is
-- touched. Without it a board with a panel would boot to a tray and an
-- empty rectangle, and the only way to a prompt would be to know which
-- button it is -- so the terminal is marked, and dio replaces the shell
-- it replaces rather than merely covering it.
for i, e in ipairs(catalog) do
	if e.boot and not front then
		local id, serr = start(i)

		if not id then
			say(e.name .. ": " .. tostring(serr))
		end
	end
end

thread.run()
