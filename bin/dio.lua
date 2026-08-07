-- dio: a window system with one window.
--
--	> dio
--
-- A launcher tray down the left, and one app filling everything right
-- of it. The tray starts an app, and an app that ends leaves the screen
-- to the next one. What the tray holds is /etc/dio.lua.
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
-- The alternative was to hand the focused app the framebuffer right and
-- take it back on a switch, and that cannot be done. Rights here are
-- copied, never revoked, so an app given the screen keeps it, and one
-- drawing over the foreground could only be stopped by killing it.
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
-- mouse read fails and it exits. That is why interrupting dio at the
-- prompt does not leave a program drawing on a screen it no longer has.
--
-- ---- the tray ----
--
-- A button starts its app when nothing is running, and stops it when it
-- is the one running. Stopping has to be there rather than being left
-- to the app: an app is given a screen and a pointer and no keyboard,
-- so bin/smiley.lua, which ends when a key is pressed, would otherwise
-- hold the screen for as long as the machine is up.
--
-- ---- what is not here yet ----
--
-- Switching. A second entry tapped while another app runs does
-- nothing. Switching wants /dev/wctl, so a backgrounded app is told to
-- redraw rather than keeping pixels it cannot afford.

local sys = require("los.sys")
local thread = require("los.thread")
local font = require("los.font")
local prog = require("prog")
local caps = require("caps")
local mousefs = require("mousefs")
local proc = require("proc")
local srv = require("srv")

local screen = prog.screen()
local N = prog.ns()

if not screen then
	io.stderr:write("dio: no framebuffer on this machine\n")
	os.exit(1)
end
if not N then
	io.stderr:write("dio: no namespace\n")
	os.exit(1)
end

local fb = screen.handle

-- ---- the framebuffer, asked directly ----
--
-- caps.fb is the wrapper every client uses, this one included; what it
-- has no op for is the cursor, which is the machine's rather than an
-- app's. So the raw request/reply is here as well.

local function ask(m)
	local rp = thread.replyport()

	m.reply = { __right = rp }
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
	io.stderr:write("dio: cannot read the screen mode\n")
	os.exit(1)
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
		io.stderr:write("dio: /etc/dio.lua: " .. tostring(res) .. "\n")
	end
end

local TRAY = conf.width
local APPX, APPY = TRAY, 0
local APPW, APPH = mode.w - TRAY, mode.h

local TRAYBG = 0x202830
local EDGE = 0x506070
local RUNNING = 0xffffff

-- one button per entry, stacked from the top. Square, so the glyph sits
-- in the middle of it whatever the tray's width is.
local BUTTON = TRAY - 6
local GAP = 4

local function buttonrect(i)
	return { x = 3, y = GAP + (i - 1) * (BUTTON + GAP),
	    w = BUTTON, h = BUTTON }
end

-- which entry a point in the tray is on, or nil for the space between.
local function buttonat(x, y)
	for i = 1, #conf.apps do
		local r = buttonrect(i)

		if x >= r.x and x < r.x + r.w and
		    y >= r.y and y < r.y + r.h then
			return i
		end
	end
	return nil
end

local running = nil		-- { pid, index }

local function drawbutton(i)
	local a = conf.apps[i]
	local r = buttonrect(i)
	local on = running and running.index == i
	local color = a.color or 0x808080

	-- a program that is not on this machine is drawn dark, so a
	-- missing file looks like one rather than like a button that does
	-- nothing when touched.
	if not N:stat(a.cmd) then
		color = 0x303030
	end
	screen.fill(r, color)

	-- the border says which app is running. Nothing else has to: with
	-- one app there is no ordering to show.
	local edge = on and RUNNING or TRAYBG

	screen.fill({ x = r.x - 1, y = r.y - 1, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y + r.h, w = r.w + 2, h = 1 }, edge)
	screen.fill({ x = r.x - 1, y = r.y - 1, w = 1, h = r.h + 2 }, edge)
	screen.fill({ x = r.x + r.w, y = r.y - 1, w = 1, h = r.h + 2 }, edge)

	local label = (a.label or a.name or "?"):sub(1, 1)
	local pix, gw, gh = font.render(label, 0x000000, color)

	if gw > 0 and gw <= r.w and gh <= r.h then
		screen.load({ x = r.x + (r.w - gw) // 2,
		    y = r.y + (r.h - gh) // 2, w = gw, h = gh }, pix)
	end
end

local function drawtray()
	screen.fill({ x = 0, y = 0, w = TRAY - 1, h = mode.h }, TRAYBG)
	screen.fill({ x = TRAY - 1, y = 0, w = 1, h = mode.h }, EDGE)
	for i = 1, #conf.apps do
		drawbutton(i)
	end
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

-- ---- serving both of them ----

local fbrecv = sys.newport()
local fbport = sys.sendright(fbrecv)
local app = mousefs.new()
local mrecv = sys.newport()
local mport = sys.sendright(mrecv)

thread.spawn(function()
	srv.serve(app.backend, mrecv)
end)

thread.spawn(function()
	while true do
		local m = thread.recv(fbrecv)

		if type(m) == "table" then
			local fn = ops[m.op]
			local reply = m.reply and m.reply.__right

			if not fn then
				if reply then
					sys.send(reply, { err = "no such op: " ..
					    tostring(m.op) })
				end
			else
				local ok, err = fn(m, reply ~= nil)

				if reply then
					sys.send(reply, ok ~= nil and
					    { ok = ok } or
					    { err = err or "failed" })
				end
			end
			if reply then
				sys.close(reply)
			end
		end
	end
end)

-- ---- starting an app ----
--
-- The namespace an app gets is dio's own, with dio's mouse in front of
-- the machine's at /dev. Union order is list order, so a mount put
-- first is what /dev/mouse resolves to -- and the app reads a pointer
-- that has never left this proc.
local function appns()
	local desc = N:describe()

	table.insert(desc, 1, { prefix = "/dev", kind = "mnt",
	    args = { port = { __right = mport } } })
	return desc
end

local function start(i)
	local a = conf.apps[i]
	local desc = appns()
	local pid, h = proc.spawn('require("prog").main()',
	    { name = a.name, ns = desc })

	if not pid then
		return nil, "spawn failed"
	end

	local out = require("stdout").out

	sys.send(h, {
		path = a.cmd,
		name = a.name,
		args = { a.name },
		env = { PATH = "/bin", HOME = "/" },
		cwd = "/",
		nsdesc = desc,
		fb = { __right = fbport },
		stdout = out and { __right = out } or nil,
		stderr = out and { __right = out } or nil,
	})
	sys.close(h)
	sys.monitor(pid)
	return pid
end

-- ---- the pointer ----
--
-- One reader of the machine's mouse, and it is this proc. A record in
-- the tray is a touch on a button; anything else is moved into app
-- space and posted to the app's own file.

local mouse, merr = N:open("/dev/mouse", "r")

if not mouse then
	io.stderr:write("dio: no /dev/mouse: " .. tostring(merr) .. "\n")
	os.exit(1)
end

drawtray()
clearapp()

local BUT1 = 1

thread.spawn(function()
	local down = false

	while true do
		local rec, rerr = mouse:read(49)

		if not rec or rec == "" then
			io.stderr:write("dio: mouse: " .. tostring(rerr) .. "\n")
			break
		end

		local x, y, b = mousefs.parse(rec)

		if x then
			local pressed = (b & BUT1) ~= 0

			if x < TRAY then
				-- the press edge, not the state: a finger
				-- held on a button must start one app, and a
				-- drag out of the tray must not start
				-- another.
				if pressed and not down then
					local i = buttonat(x, y)

					if i and running and
					    running.index == i then
						-- the same button again stops
						-- it, which is the only way
						-- out an app has here: it was
						-- given no keyboard, so a
						-- program that ends on a
						-- keystroke would never end.
						--
						-- Marked as asked-for, so
						-- what follows is reported as
						-- an app ending rather than
						-- as an app dying.
						running.stopped = true
						pcall(sys.kill, running.pid)
					elseif i and not running then
						local pid = start(i)

						if pid then
							running = { pid = pid,
							    index = i }
							drawbutton(i)
						end
					end
				end
			else
				app.post(mousefs.format(x - APPX, y - APPY, b))
			end
			down = pressed
		end
	end
end)

-- ---- what is left of this thread ----
--
-- The exits. An app that ends gives the screen back, so the area it had
-- is cleared and its button stops being marked -- which is the whole of
-- what "the app ended" means when there is nothing behind it.
thread.spawn(function()
	while true do
		local m = thread.recv(sys.SELF)

		if type(m) == "table" and m.exit and running and
		    m.exit == running.pid then
			local i = running.index
			local asked = running.stopped

			running = nil
			-- a proc killed on purpose is held as a corpse like
			-- any other, and nothing is going to inspect this
			-- one: the person who tapped the button knows why it
			-- stopped, and a corpse holds the whole working set
			-- until something reaps it.
			if asked then
				pcall(sys.reap, m.exit)
			end
			drawbutton(i)
			clearapp()
			if not m.normal and not asked then
				io.stderr:write("dio: " ..
				    tostring(conf.apps[i].name) .. ": " ..
				    tostring(m.reason) .. "\n")
			end
		end
	end
end)

thread.run()
