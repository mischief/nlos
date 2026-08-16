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
-- ---- dio grants a window, and is not in the pixel path ----

-- An image per app, and a framebuffer session over it. That right is
-- what the app is handed, so its pixels never come here: what is left
-- is where the window sits and whether it is on the glass, which is a
-- message per switch rather than one per drawing call.

-- An app cannot name the glass or another app's window, and loses its
-- own when dio drops its copy of the right. bin/scribble.lua, written
-- for a whole screen, runs here unchanged.

-- The pointer arrives the same way: dio holds the machine's receive
-- right and gives each app its own, with the coordinates moved into
-- app space. A tray touch never reaches an app because it never
-- leaves dio, and the cursor is moved from here.
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
-- vertically, which is this machine's scroll and what lib/mouse.lua
-- already reports as buttons 8 and 16. So how many apps may run is a
-- question about memory rather than about how tall the screen is. The
-- launcher does not scroll with them: it is the way to start anything,
-- so it stays where it can be reached.
--
-- ---- several apps, one window ----
--
-- Every app keeps running whether or not it is in front. What being in
-- front buys is the glass and the pointer: a draw from any other app is
-- dropped here, and the pointer's records go to one app.
--
-- Dropped rather than refused. An app behind has nothing to fix, and an
-- error per drawing call would make every program handle a window
-- system it otherwise need not know about. It is told to draw itself
-- again on its event port when it comes back.
--
-- So there are no saved pixels anywhere: coming to the front is a
-- cleared rectangle and one message. An app that cannot redraw
-- itself comes back empty, which is the price of a window system on a
-- board with 4MB.

local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")
local draw = require("draw")
local sendwait = require("client.rpc").sendwait
local mouse = require("mouse")
local proc = require("proc")

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
local dnsh = job.dns and job.dns.__right
-- the machine's entropy as data, which lib/svc.lua hands every
-- service. Expanded here so each app gets its own draw.
local rng = job.seed and
    require("crypto.drbg").new(job.seed) or nil
local ptr = job.ptr and job.ptr.__right
-- the radio, lent on to an app whose entry asks for it. Held rather
-- than used: dio draws, and what talks bluetooth is a program.
local bleh = job.ble and job.ble.__right

local function say(s)
	if cons then
		sys.send(cons, { op = "write", data = "dio: " .. s .. "\n" })
	end
end

-- the namespace this proc was given, which is where /etc/dio.lua, the
-- programs are. Described from here rather than taken
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

local screen = draw.new(fb)

-- ---- the framebuffer, asked directly ----
--
-- draw is the wrapper every client uses, this one included; what it
-- has no op for is the cursor, which is the machine's rather than an
-- app's. So the raw request/reply is here as well.

local function ask(m, h)
	local rp, send = thread.replyport()

	m.reply = { __right = send }

	-- sendwait, not send: a full queue drops a bare send, and what is
	-- dropped here is the request this then waits for an answer to.
	-- A busy screen would wedge the app that asked.
	local sent, why = sendwait(h or fb, m)

	if not sent then
		return nil, why
	end

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

-- a window image is in the panel's own format, so putting one on the
-- glass is a copy rather than a conversion of every pixel. A screen
-- whose format is not one an image can have -- efi reports bltonly --
-- leaves this nil, and fb picks its default.
local IMGFMT = { bgrx = true, ["r5g6b5"] = true }
local FMT = IMGFMT[mode.format] and mode.format or nil

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
--
-- The memory to ask about is the pool the lua heaps come from, which on
-- this board is PSRAM and is not the one sys.stats calls memavail. A
-- terminal and its shell are about half a megabyte of heap and some 3KB
-- of internal sram, so watching the sram would let six of them fill the
-- heap while the figure being watched barely moved.
local MAXAPPS = 6
local APPHEAP = 512 * 1024
local HEAPFLOOR = 2 * APPHEAP

-- what the pool has left, or nil where the machine cannot say -- then
-- the count above is the whole of the limit.
local function heapleft()
	local ok, st = pcall(sys.stats)
	local avail = ok and type(st) == "table" and
	    (st.chunkavail or st.memavail)

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

-- A button's glyph, kept by the screen rather than rendered and shipped
-- again on every switch, scroll and launch. The set is what the
-- catalogue holds, so it is small and it stops growing.
local glyphs = {}

local function glyph(ch, color)
	local key = ch .. ":" .. color
	local g = glyphs[key]

	if g then
		return g
	end

	local pix, gw, gh = font.render(ch, 0x000000, color)

	if gw <= 0 then
		return nil
	end

	local id = screen.alloc(gw, gh)

	if not id then
		return nil			-- draw it the long way
	end
	screen.load({ x = 0, y = 0, w = gw, h = gh }, pix, true, false, nil,
	    id)
	g = { id = id, w = gw, h = gh }
	glyphs[key] = g
	return g
end

-- one button: a filled square, a border saying whether it is in front,
-- and a glyph in the middle.
local function drawface(r, color, label, edge)
	screen.fill(r, color)
	screen.fill({ x = r.x - 1, y = r.y - 1, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y + r.h, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y - 1, w = 1, h = r.h + 2 }, edge)
	screen.fill({ x = r.x + r.w, y = r.y - 1, w = 1, h = r.h + 2 }, edge)

	local g = glyph(label:sub(1, 1), color)

	if g and g.w <= r.w and g.h <= r.h then
		screen.draw(nil, g.id, { x = 0, y = 0, w = g.w, h = g.h },
		    { x = r.x + (r.w - g.w) // 2,
		      y = r.y + (r.h - g.h) // 2 })
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

local WINAT = { x = APPX, y = APPY }

local function clearapp()
	screen.fill({ x = APPX, y = APPY, w = APPW, h = APPH }, 0x000000, true)
end

-- ---- the app selector ----
--
-- A mode of this proc rather than an app of its own, for two reasons.
--
-- It needs no saved pixels: switching already clears the rectangle and
-- tells the app coming back to redraw itself from its own state, so the
-- selector can borrow the glass and hand it back with the machinery
-- that is already here.
--
-- And starting an app is authority. An app that could start apps would
-- need a right to say so, and every program that could reach that right
-- would inherit the power -- so it stays with the proc that owns the
-- screen, which is the same reason dio proxies the framebuffer instead
-- of lending it.
local CW, CH = font.size()
local ROWH = 2 * CH + 6
local HEADH = CH + 6
local SELBG = 0x101418
local SELNAME = 0xffffff
local SELDESC = 0x8895a0
local SELGONE = 0x505050	-- a program this machine has not got
local SELHEAD = 0x60707c
local SELRULE = 0x2a3138

local selecting = false
local seloff = 0
local wasfront = nil

-- what the selector shows, as headings and entries in one list.
-- Grouped by the entry's `category`, in the order the categories first
-- appear in /etc/dio.lua, so the file still says what comes first.
-- Headings only where there is more than one group: a single category
-- is not a grouping, it is a title nobody asked for.
local selrows = {}

local function buildrows()
	local order, members = {}, {}

	for k, e in ipairs(catalog) do
		local c = e.category or ""

		if not members[c] then
			members[c] = {}
			order[#order + 1] = c
		end
		table.insert(members[c], k)
	end

	-- the unnamed group last wherever it first appeared: it is the
	-- leftovers, and leftovers do not come first.
	if members[""] and #order > 1 then
		for i, c in ipairs(order) do
			if c == "" then
				table.remove(order, i)
				order[#order + 1] = c
				break
			end
		end
	end

	local heads = #order > 1

	selrows = {}
	for _, c in ipairs(order) do
		if heads then
			selrows[#selrows + 1] = { head = c ~= "" and c or
			    "other" }
		end
		for _, k in ipairs(members[c]) do
			selrows[#selrows + 1] = { k = k }
		end
	end
end

buildrows()

local function rowheight(r)
	return r.head and HEADH or ROWH
end

-- the rows that fit from seloff down, and where each one sits
local function laidout()
	local out = {}
	local y = APPY

	for i = seloff + 1, #selrows do
		local h = rowheight(selrows[i])

		if y + h > APPY + APPH then
			break
		end
		out[#out + 1] = { i = i, y = y, h = h }
		y = y + h
	end
	return out
end

-- the furthest this may be scrolled: the offset at which the last row
-- still lands on the screen, so scrolling stops with the end in view
-- rather than running the list off the top.
local function selmost()
	local y = 0
	local most = #selrows

	for i = #selrows, 1, -1 do
		y = y + rowheight(selrows[i])
		if y > APPH then
			break
		end
		most = i - 1
	end
	if most < 0 then
		most = 0
	end
	return most
end

-- text into the app area, clipped to what fits across it
local function seltext(x, y, s, color, bg)
	local room = (APPW - (x - APPX)) // CW

	if room < 1 or s == "" then
		return
	end

	local pix, w, h = font.render(s:sub(1, room), color, bg or SELBG, true)

	if w > 0 then
		screen.load({ x = x, y = y, w = w, h = h }, { __buf = pix })
	end
end

local function drawentry(k, y)
	local e = catalog[k]
	local here = N:stat(e.cmd) ~= nil
	local name = e.name or "?"
	local n = 0

	for _, a in pairs(apps) do
		if a.entry == k then
			n = n + 1
		end
	end
	-- how many are already up, because "another one" and "the first
	-- one" are different decisions.
	if n > 0 then
		name = ("%s  (%d running)"):format(name, n)
	end
	if not here then
		name = name .. "  (missing)"
	end

	-- the entry's own colour, as a mark down the side: the same
	-- colour its buttons wear in the tray.
	screen.fill({ x = APPX + 2, y = y + 3, w = 3, h = ROWH - 6 },
	    here and (e.color or 0x808080) or SELGONE)
	seltext(APPX + 9, y + 2, name, here and SELNAME or SELGONE)
	seltext(APPX + 9, y + 2 + CH, e.desc or e.cmd or "", SELDESC)
end

-- a heading, with a rule across the width under it: the name alone
-- reads as another entry, and the rule is what says it divides.
local function drawhead(name, y)
	seltext(APPX + 6, y + 2, name, SELHEAD)
	screen.fill({ x = APPX + 6, y = y + HEADH - 2,
	    w = APPW - 12, h = 1 }, SELRULE)
end

local function drawselector()
	screen.fill({ x = APPX, y = APPY, w = APPW, h = APPH }, SELBG, true)

	for _, at in ipairs(laidout()) do
		local r = selrows[at.i]

		if r.head then
			drawhead(r.head, at.y)
		else
			drawentry(r.k, at.y)
		end
	end
end

-- which entry a point in the app area is on, while the selector is up.
-- A heading is not one: touching it does nothing, rather than starting
-- whatever happens to sit under the name.
local function selectorat(x, y)
	if x < APPX or x >= APPX + APPW then
		return nil
	end
	for _, at in ipairs(laidout()) do
		if y >= at.y and y < at.y + at.h then
			return selrows[at.i].k
		end
	end
	return nil
end

-- ---- one window each, and one of them in front ----
--
-- Every app gets its own framebuffer port, its own pointer and its own
-- event port. A port carries no sender identity, so a shared port could
-- not tell whose draw had arrived -- and knowing that is the whole of
-- what focus means here.
--
-- an instance is:
--	{ id, entry, name, pid, winid, fbport, mouse, ev, evsend,
--	  wstate, kind }

-- ---- the window, as a message ----

-- "visible", "hidden" or "redraw", on the port the keys arrive on. Only
-- a change is an event, except redraw: the pixels are gone whatever the
-- app believes about its focus. A full port is dropped rather than
-- waited on -- this is the state and not a log of it, and waiting would
-- park the switch behind an app that stopped reading.
local function tellwin(a, state)
	if state ~= "redraw" and state == a.wstate then
		return
	end
	-- recorded only if it went. A drop leaves the app believing what
	-- it last heard, and this believing the same, so the next change
	-- is sent rather than suppressed as one it already knows -- which
	-- would leave an app that missed a "visible" blank until the one
	-- after that.
	if sys.send(a.evsend, { t = "win", state = state }) then
		a.wstate = state
	end
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
	-- the window, and a session over it. That right is the app's
	-- screen: it draws into the image and never into this proc, so
	-- nothing here is between an app and its pixels.
	local winid, werr = screen.alloc(APPW, APPH, FMT, 0)

	if not winid then
		say("no window: " .. tostring(werr))
		return nil
	end

	local win = screen.session(winid)

	if not win then
		screen.free(winid)
		say("no window session")
		return nil
	end

	-- one event port per app, not one shared: keys, window state and
	-- the pointer belong to whichever app is in front, and a port
	-- handed to two of them would give a key to whichever asked first.
	local ev = sys.newport("dio.ev")
	local evsend = sys.sendright(ev)
	local a = {
		id = nextid,
		entry = entryidx,
		kind = kind,
		winid = winid, fbport = win.handle,
		ev = ev, evsend = evsend,
	}

	-- The pointer has a port of its own, as plan 9 gives it a file of
	-- its own. Records are dropped and coalesced where a key and a
	-- window state must not be, and one queue can hold one such rule.
	-- A terminal lends this to the programs it runs; it reads keys.
	a.ptr = sys.newport("dio.ptr")
	a.ptrsend = sys.sendright(a.ptr)
	a.mouse = mouse.queue(a.ptrsend)

	-- a fresh window is empty, so the first thing an app is told is to
	-- paint it. Sent before the app exists, and waits on the port.
	tellwin(a, "redraw")

	nextid = nextid + 1
	apps[a.id] = a
	order[#order + 1] = a.id
	return a
end

-- an instance and everything the tray knows about it, gone.
local function forget(id)
	local k = slotof(id)
	local a = apps[id]

	-- the window is dio's image and the app held only a session over
	-- it, so this is what actually returns the pixels
	if a and a.winid then
		screen.place(a.winid, WINAT, false)
		screen.free(a.winid)
		-- and dio's own right to the session, without which fb
		-- keeps the space the app allocated in
		sys.close(a.fbport)
	end
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
				sys.send(a.evsend, c)
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
		-- the pointer, for the programs it runs rather than for
		-- itself: a shell reads keys, and scribble reads this.
		ptr = { __right = a.ptr },
		-- the event port, which for a terminal is its keyboard: the
		-- window messages riding on it are not keystrokes and the
		-- console hands them on rather than typing them.
		kbd = { __right = a.ev },
		-- the serial line, for what the terminal cannot report
		-- about itself. Its own output goes to the glass.
		cons = cons and { __right = cons } or nil,
		tcp = tcp and { __right = tcp } or nil,
		dns = dnsh and { __right = dnsh } or nil,
		seed = rng and rng.bytes(32) or nil,
		-- and power, which is what bin/reboot.lua spends. The panel
		-- is a local terminal: it holds what the serial console
		-- holds, and a session over the network does not.
		power = power and { __right = power } or nil,
		-- the ip task, which is also the udp server: bin/host.lua
		-- and bin/date.lua ask a server one question each.
		ip = ip and { __right = ip } or nil,
	})
	-- the handle is kept, not closed: it is a right to the app's
	-- own port, and sys.kill asks whether the caller holds one. Drop
	-- it and the tray can start an app it can never stop -- which is
	-- what a second tap did for as long as this closed it here.
	a.ctl = h
	return pid
end

-- ---- switching ----
--
-- The app in front owns the glass and the pointer; every other one
-- keeps running with its draws dropped. Coming to the front is an area
-- cleared and a "redraw" on its event port, so an app paints from its own
-- state onto a known-empty rectangle -- which is what buys a machine
-- this size a window system with no saved pixels anywhere.
local function focus(id)
	if front == id and not selecting then
		return
	end

	-- whatever the selector was covering, it is not covering it now
	selecting = false

	local was = front

	front = id
	if was and apps[was] then
		tellwin(apps[was], "hidden")
		screen.place(apps[was].winid, WINAT, false)
	end
	if id and apps[id] then
		tellwin(apps[id], "visible")
		screen.place(apps[id].winid, WINAT, true)
	else
		clearapp()
	end
	-- keys follow the front, to a terminal or to a program whose
	-- entry asked for them. A pointer program is given none: what it
	-- does not read would sit in a port nobody drains.
	local fa = id ~= nil and apps[id] or nil

	wantkeys = fa ~= nil and (fa.kind == "term" or
	    (catalog[fa.entry] or {}).keys == true)
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

	local left = heapleft()

	if left and left < HEAPFLOOR + APPHEAP then
		return nil, ("%dK of heap left is not enough to start another")
		    :format(left // 1024)
	end

	entry.idx = i
	local a = newapp(i, entry.kind)

	if not a then
		return nil, "no window"
	end
	a.name = instname(entry, a.id)

	-- dio's own namespace, unchanged: an app's window reaches it as a
	-- capability rather than as a file, so there is nothing per-app in
	-- here to mount.
	local desc = N:describe()
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
				ptr = { __right = a.ptr },
				-- window state, and keystrokes where the
				-- entry asked for them: a picker that takes
				-- a passphrase needs keys. The pump above
				-- delivers only while such an app is in
				-- front.
				ev = { __right = a.ev },
				keys = entry.keys or nil,
				-- only where the entry named it: a right
				-- nobody asked for is one more program
				-- that could use the radio.
				ble = entry.ble and bleh and
				    { __right = bleh } or nil,
				-- entropy of its own, drawn from ours: a
				-- program that makes a key needs one, and
				-- two apps must not draw the same bytes.
				seed = rng and rng.bytes(32) or nil,
				stdout = cons and { __right = cons } or nil,
				stderr = cons and { __right = cons } or nil,
			})
			a.ctl = h	-- kept, as in startterm: see there
		else
			err = "spawn failed"
		end
	end

	if not pid then
		forget(a.id)
		return nil, err
	end
	a.pid = pid
	sys.monitor(pid)
	-- the list grew, so every button below the new one moved
	drawlist()
	focus(a.id)
	return a.id
end

-- ---- the launcher ----
--
-- The button opens the selector, and opens it over nothing: the app in
-- front is put down first, so its draws are dropped while the list is
-- up and it is asked to paint itself again when it comes back. Which is
-- switching, and costs this nothing.
local function opensel()
	wasfront = front
	if front then
		local was = front

		front = nil
		if apps[was] then
			tellwin(apps[was], "hidden")
			-- off the glass, so the list is not drawn over by
			-- an app that keeps painting behind it
			screen.place(apps[was].winid, WINAT, false)
		end
		wantkeys = false
		drawbutton(was)
	end
	selecting = true
	seloff = 0
	drawselector()
	drawplus()
end

-- back to what was in front, or to nothing where that app has gone or
-- there was none.
local function closesel()
	selecting = false
	if wasfront and apps[wasfront] then
		local back = wasfront

		front = nil		-- so focus does not think it is there
		focus(back)
	else
		front = nil
		clearapp()
	end
	wasfront = nil
	drawplus()
end

local function pick(k)
	local id, serr = start(k)

	if id then
		wasfront = nil
		return		-- start focused it, which closed the list
	end
	say(((catalog[k] and catalog[k].name) or "app") .. ": " ..
	    tostring(serr))
	-- and say it where the finger is: the row stays, the launcher
	-- goes red, and the reason is on the console.
	thread.spawn(function()
		drawface(PLUS, 0xcc0000, "+", TRAYBG)
		thread.sleep(700)
		drawplus()
	end)
end

-- ---- the pointer ----
--
-- The machine's pointer port, held here. A record in the tray is a
-- touch on a button; anything else is moved into app space and posted
-- to the app's own mouse.

-- The cursor follows the finger from here, with no client in the loop:
-- on the finger rather than a round trip behind whatever is reading.
-- The pointer reports and the framebuffer draws, as in plan 9.

if not ptr then
	say("no pointer")
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
--
-- 800 rather than 500: a panel tap is a press and a release with the
-- finger settling between them, and two of them measured over half a
-- second apart -- so at 500 the gesture could not be made at all, by a
-- finger or by an injected record.
local DOUBLE = 800
local lasttap, lastms = nil, 0

-- the wheel, as lib/mouse.lua reports it: 8 up, 16 down, one click
-- per record. On the T-Deck that is the trackball rolled vertically,
-- which is the machine's scroll and is already what a list scrolls
-- with -- so the tray uses it rather than a gesture of its own.
local WHEELUP = 8
local WHEELDOWN = 16

thread.spawn(function()
	local down = false
	local bad = 0

	-- how long to wait before offering a full app's port its records
	-- again. Only reached when an app is behind, so an idle machine
	-- still parks on the pointer and nothing else.
	local RETRYMS = 20

	while true do
		local a = front and apps[front]
		local waiting = a and a.mouse and a.mouse.pending() > 0
		local rec

		-- A record the app's port would not take waits in its
		-- queue, and the next post is what offers it again. If the
		-- pointer then goes still there is no next post, and the
		-- last thing said -- a release, most of the time -- would
		-- sit there. So wake and offer it rather than park.
		if waiting then
			rec = thread.recvtimeout(ptr, RETRYMS)
			if rec == nil then
				a.mouse.retry()
				goto continue
			end
		else
			rec = thread.recv(ptr)
		end

		local x, y, b = mouse.parse(rec)

		-- the cursor, before the record is routed: it belongs to
		-- the machine, so it moves whoever the record is for. A
		-- wheel click carries where it scrolled and moves nothing.
		if x and fb and not mouse.iswheel(rec) then
			sys.send(fb, { op = "cursor", x = x, y = y,
			    on = true })
		end

		if not x then
			bad = bad + 1
			if bad == 1 then
				say(("mouse: not a record: %s")
				    :format(type(rec) == "string" and
				    ("%d bytes, %q"):format(#rec,
				    rec:sub(1, 24)) or type(rec)))
			end
			if bad >= BADMAX then
				say(("mouse: %d bad records; the tray is "
				    .. "no longer answering"):format(bad))
				break
			end
		else
			bad = 0
			local pressed = (b & BUT1) ~= 0
			local iswheel = (b & (WHEELUP | WHEELDOWN)) ~= 0
			local by = ((b & WHEELDOWN) ~= 0) and 1 or -1

			-- A wheel record carries where the pointer is, and on
			-- a panel that is where a finger last was: nothing
			-- hovers. Routing it by that position sends a roll to
			-- whatever was last touched, so the ball follows the
			-- front app instead, as the keyboard does. The tray
			-- keeps it while its list is open, or while a finger
			-- is on the tray.
			if iswheel then
				if selecting then
					local most = selmost()
					local to = seloff + by

					if to < 0 then
						to = 0
					elseif to > most then
						to = most
					end
					if to ~= seloff then
						seloff = to
						drawselector()
					end
				elseif x < TRAY and pressed then
					if scrollto(trayoff + by) then
						drawlist()
					end
				elseif front and apps[front] and apps[front].mouse then
					apps[front].mouse.post(x - APPX,
					    y - APPY, b)
				end
			elseif x < TRAY then
				if pressed and not down then
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
						if selecting then
							closesel()
						else
							opensel()
						end
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

						local kok, kerr =
						    pcall(sys.kill,
						    apps[hit].pid)

						if not kok then
							apps[hit].stopped = nil
							say("kill: " ..
							    tostring(kerr))
						end
					elseif hit and apps[hit] then
						-- running, behind: bring it
						-- forward. It keeps running
						-- either way -- what changes
						-- is whose draws reach the
						-- glass.
						focus(hit)
					end
				end
			elseif selecting then
				-- the list has the glass, so it has the
				-- pointer too: nothing is in front to give
				-- it to. Its wheel is handled above.
				if pressed and not down then
					local k = selectorat(x, y)

					if k then
						pick(k)
					end
				end
			elseif front and apps[front] and apps[front].mouse then
				-- the pointer belongs to the app in front,
				-- and to nothing else: an app behind sees no
				-- part of a stroke it is not in.
				apps[front].mouse.post(x - APPX,
				    y - APPY, b)
			end
			down = pressed
		end

		::continue::
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
			-- and only now the right to it goes back: sys.reap
			-- asks the same question sys.kill does, so closing
			-- this any earlier leaves the corpse held -- with
			-- the whole working set that made it worth reaping.
			if a.ctl then
				sys.close(a.ctl)
				a.ctl = nil
			end
			-- the event pair, which no thread waits on: the app
			-- received on it and dio only ever sent, keys,
			-- window state and the pointer alike.
			sys.close(a.evsend)
			sys.close(a.ev)
			-- a terminal's pointer pair, on the same terms
			if a.ptr then
				sys.close(a.ptrsend)
				sys.close(a.ptr)
				a.ptr, a.ptrsend = nil, nil
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
