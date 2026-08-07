-- dio: the framebuffer, narrowed and moved over.
--
-- The first piece of a window system that has no overlapping windows.
-- See /tmp/dio.md for the whole idea; this is the part everything else
-- hangs off, and it is testable alone.
--
-- What it does: hold the one framebuffer right, speak the same protocol
-- task/fb.lua does, and answer for a rectangle of the screen rather
-- than the screen. A client asks for the mode and is told the app area's
-- size; it draws at 0,0 and the pixels land right of the tray.
--
-- Proxied rather than lent, and that is the design decision the rest
-- depends on. Handing the focused app the fb right would be faster and
-- could not be undone: rights here are copied, never revoked, so an app
-- that has the framebuffer keeps it, and one drawing while another is
-- focused could only be stopped by killing it. A proxy drops that draw
-- instead, and gets coordinate translation in the same move.
--
-- Spawned with a message carrying the screen:
--	{ fb = {__right=} }
--
-- and hands back the same protocol on its own port:
--	{op="mode"} {op="modes"} {op="setmode"} {op="fill"} {op="load"}
--	{op="unload"} {op="scroll"} {op="cursor"}

local sys = require("los.sys")
local thread = require("los.thread")

local job = ... or thread.recv(sys.SELF)
local fb = job.fb and job.fb.__right

if not fb then
	print("dio: no framebuffer")
	return
end

-- the launcher strip, on the left. Only its width matters here: what
-- goes in it is the next piece of work, and until then it is painted
-- once so the app area's edge is visible.
local TRAY = 28

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

local screen = ask({ op = "mode" })

if not screen then
	print("dio: cannot read the screen mode")
	return
end

-- what an app is told it has. One rectangle, and every coordinate a
-- client sends is relative to its corner.
local APPX, APPY = TRAY, 0
local APPW, APPH = screen.w - TRAY, screen.h

-- paint the tray once, so the split is visible before anything is in it
ask({ op = "fill", r = { x = 0, y = 0, w = TRAY, h = screen.h },
    color = 0x202830 })
ask({ op = "fill", r = { x = TRAY - 1, y = 0, w = 1, h = screen.h },
    color = 0x506070 })

-- a client's rectangle, moved into the app area.
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

local ops = {}

-- the app area's size, in place of the screen's. An app that asks what
-- it has is answered with what it has.
function ops.mode()
	return { n = screen.n, w = APPW, h = APPH, format = screen.format }
end

function ops.modes()
	return { ops.mode() }
end

-- refused: the mode belongs to the machine, and an app that could
-- change it would change it for whatever else is running.
function ops.setmode()
	return nil, "the mode is not an app's to set"
end

function ops.fill(m)
	local r, err = place(m.r)

	if not r then
		return nil, err
	end
	return ask({ op = "fill", r = r, color = m.color })
end

function ops.load(m)
	local r, err = place(m.r)

	if not r then
		return nil, err
	end
	return ask({ op = "load", r = r, data = m.data })
end

function ops.unload(m)
	local r, err = place(m.r)

	if not r then
		return nil, err
	end
	return ask({ op = "unload", r = r })
end

function ops.scroll(m)
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
	return ask({ op = "scroll", r = r, to = { x = dst.x, y = dst.y } })
end

-- the cursor is the machine's, not an app's: it is drawn over whatever
-- is on the glass, tray included, and it follows the finger rather than
-- anything a client asked for. Passed through in screen coordinates.
function ops.cursor(m)
	return ask({ op = "cursor", x = m.x, y = m.y, on = m.on })
end

while true do
	local m = thread.recv(sys.SELF)

	if type(m) == "table" then
		local fn = ops[m.op]
		local reply = m.reply and m.reply.__right

		if not fn then
			if reply then
				sys.send(reply,
				    { err = "no such op: " .. tostring(m.op) })
			end
		else
			local ok, err = fn(m)

			if reply then
				sys.send(reply, ok ~= nil and { ok = ok } or
				    { err = err or "failed" })
			end
		end
		if reply then
			sys.close(reply)
		end
	end
end
