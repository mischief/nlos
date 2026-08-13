-- fb: the sole task anywhere with los.platform.fb (the raw
-- framebuffer). every other proc holds, at most, a send-right to this
-- task's mailbox and talks by message.
--
-- this is the screen and only the screen. it knows rectangles, pixels
-- and a fill colour; it does not know what a window is, what a font is,
-- or who is drawing. that is deliberate and it is plan 9's split: this
-- task is libmemdraw's Memimage plus memload/memunload, and a
-- rio-shaped thing is a separate proc above it holding a right to this
-- one -- libmemlayer, which stacks windows on a screen the layer below
-- never hears about.
--
-- the protocol:
--   {op="mode", reply=}                     -> {n=,w=,h=,format=}
--   {op="modes", reply=}                    -> { {n=,w=,h=,format=}, ... }
--   {op="setmode", n=, reply=}              -> true
--   {op="fill", r=, color=, reply=}         -> true
--   {op="load", r=, data=, reply=}          -> true
--   {op="unload", r=, reply=}               -> the pixels
--   {op="scroll", r=, to=, reply=}          -> true
--   {op="cursor", x=, y=, on=, reply=}      -> true
--   {op="alloc", w=, h=, fmt=}              -> an image id
--   {op="free", id=}, {op="draw", dst=, src=, r=, p=}
--   {op="line", id=, p0=, p1=, thick=, color=}
--
-- ---- images the server keeps ----

-- alloc answers an id and the pixels stay here, as devdraw's 'd'
-- carries ids and no pixels. fill, load, line and draw take an `id`,
-- and absent is the screen, so a caller that allocates nothing writes
-- what it wrote before. A picture crosses the port once, not per frame.

-- Freeing is the caller's: this loop cannot tell one sender from
-- another, so it cannot drop a dead client's images as devdraw does.
--
-- a rectangle is {x=,y=,w=,h=} and `to` is a {x=,y=} destination
-- corner. reply is optional on every op that only answers true: a
-- client streaming loads should not pay a round trip per rectangle, and
-- can send one final op with a reply to find out whether any of them
-- failed.
--
-- every reply is a table, {ok=<result>} or {err=<message>}, because
-- sys.send carries exactly one value and a bare nil would lose the
-- reason. errors are reported to whoever asked and never raised out of
-- the loop -- this task dying takes the screen with it for the rest of
-- the boot, since nothing re-grants PRIV_FB.

local sys = require("los.sys")

local platform = require("los.platform.fb")

local function rect(r)
	if type(r) ~= "table" then
		error("no rectangle", 0)
	end
	return r.x or 0, r.y or 0, r.w or 0, r.h or 0
end

-- on first image op, not at boot: a machine whose clients only fill and
-- load never allocates one, and this task is started on every platform.
local memdraw

local function md()
	memdraw = memdraw or require("memdraw")
	return memdraw
end

-- ---- one image space per client ----

-- Ids are per session, as 9P fids are per connection: a shared table
-- lets a client name another's image by guessing a small integer, and
-- a port carries no sender identity. lib/srv.lua says the same of fids.
local anon = { images = {}, nextid = 1 }

-- parallel: ports is the set altrecv waits on, spaces[i] is whose
-- images arrive on ports[i]. [1] is this task's own port, for a client
-- that never asked for a session.
local ports = { sys.SELF }
local spaces = { anon }
local nsession = 0

-- the image an op names. Absent is the screen, or in a windowed session
-- that session's window, which is what keeps an app inside it: the
-- glass has no name there at all. Raises on an id that was never given
-- out, which is a client bug and not a blank draw.
local function image(space, id)
	if id == nil then
		return space.win
	end

	local img = space.images[id]

	if not img then
		error("no such image: " .. tostring(id), 0)
	end
	return img
end

-- the part of r that is on the glass, in image coordinates, or nothing.
-- r is in the image; `at` is where the window manager put the window.
local function onglass(img, r)
	if not img or not img.on or not r then
		return nil
	end

	local x = math.max(r.x or 0, 0)
	local y = math.max(r.y or 0, 0)
	local x1 = math.min((r.x or 0) + (r.w or 0), img.w)
	local y1 = math.min((r.y or 0) + (r.h or 0), img.h)

	if x1 <= x or y1 <= y then
		return nil
	end
	return { x = x, y = y, w = x1 - x, h = y1 - y }
end

-- what an app draws is on the glass as soon as it draws it, which is
-- the behaviour it had when it drew to the glass. The pixels are cut
-- out of the image, so a caller with the pixels already in hand should
-- send those instead of coming here.
local function shown(img, r)
	local part = onglass(img, r)

	if part then
		platform.load(img.at.x + part.x, img.at.y + part.y,
		    part.w, part.h, img:bytes(part), img.fmt)
	end
end

local function point(p)
	if type(p) ~= "table" then
		error("no point", 0)
	end
	return p.x or 0, p.y or 0
end

local ops = {}

-- a client's own image space, and a right to talk on it. Ours is closed
-- once the reply has gone, so the client holds the only send right and
-- sys.hungup tells us when it has gone. m.win, an id in the asking
-- space, makes the session a window on that image.
function ops.session(m, space)
	local recv = sys.newport("fb.session")
	local send = sys.sendright(recv)

	ports[#ports + 1] = recv
	spaces[#spaces + 1] = { images = {}, nextid = 1,
	    win = m and m.win and image(space, m.win) }
	nsession = nsession + 1
	return { port = { __right = send } }, send
end

-- where a window image sits on the glass, and whether it is on it. The
-- window manager holds an id for the image and says; the app holding
-- the session cannot, having no id for its own window.
function ops.place(m, space)
	local img = image(space, m.id)

	if not img then
		error("place: no image", 0)
	end
	img.at = { x = (m.at and m.at.x) or 0, y = (m.at and m.at.y) or 0 }
	if m.on ~= nil then
		img.on = m.on and true or false
	end
	if img.on then
		shown(img, img:rect())
	end
	return true
end

function ops.alloc(m, space)
	local w, h = m.w or 0, m.h or 0

	if w <= 0 or h <= 0 then
		error("alloc: " .. w .. "x" .. h, 0)
	end

	local id = space.nextid

	space.nextid = id + 1
	space.images[id] = md().image(w, h, m.color, m.fmt)
	return id
end

function ops.free(m, space)
	space.images[m.id] = nil
	return true
end

-- a window's client asks this to size itself, so it must answer the
-- window rather than the glass behind it.
function ops.mode(m, space)
	local mode = platform.mode()

	if space.win then
		local r = space.win:rect()

		return { n = mode.n, w = r.w, h = r.h,
		    format = space.win.fmt }
	end
	return mode
end

function ops.modes()
	return platform.modes()
end

function ops.setmode(m)
	platform.setmode(m.n)
	return true
end

function ops.fill(m, space)
	local x, y, w, h = rect(m.r)
	local img = image(space, m.id)

	if img then
		img:fill(m.r, m.color or 0)

		-- to the panel as a fill, not as pixels cut back out of
		-- the image it was just written into
		local part = onglass(img, m.r)

		if part then
			platform.fill(img.at.x + part.x, img.at.y + part.y,
			    part.w, part.h, m.color or 0)
		end
		return true
	end
	platform.fill(x, y, w, h, m.color or 0)
	return true
end

function ops.line(m, space)
	local img = image(space, m.id)
	local x0, y0 = point(m.p0)
	local x1, y1 = point(m.p1)

	if not img then
		error("line: the screen cannot be read, so a line on it "
		    .. "would have to be repaired by the caller", 0)
	end
	img:line(md().pt(x0, y0), md().pt(x1, y1), m.thick or 1,
	    m.color or 0)

	-- the ends and the width, which is all a line's extent is
	local pad = (m.thick or 1) + 1

	shown(img, { x = math.min(x0, x1) - pad, y = math.min(y0, y1) - pad,
	    w = math.abs(x1 - x0) + 2 * pad, h = math.abs(y1 - y0) + 2 * pad })
	return true
end

-- src into dst at p. dst absent is the screen, and that is the one
-- direction that reaches the panel: the pixels are here already, so it
-- is a load with nothing crossing the port.
function ops.draw(m, space)
	local src = image(space, m.src)
	local dst = image(space, m.dst)

	if not src then
		error("draw: no source image", 0)
	end

	local r = m.r or src:rect()
	local x, y = point(m.p or { x = r.x, y = r.y })

	if dst then
		dst:draw(md().pt(x - r.x, y - r.y), src, r)
		shown(dst, { x = x, y = y, w = r.w, h = r.h })
		return true
	end
	platform.load(x, y, r.w, r.h, src:bytes(r), src.fmt)
	return true
end

-- m.fmt names what the client's bytes are; absent is bgrx. The driver
-- takes what mode() said it takes without converting, and converts
-- anything else.
function ops.load(m, space)
	local x, y, w, h = rect(m.r)
	local img = image(space, m.id)

	if img then
		if not img:rows(x, y, w, h, m.data, m.fmt) then
			local band = md().fromBytes(w, h, m.data, m.fmt)

			img:draw(md().pt(x, y), band, band:rect())
		end

		-- the client's own bytes to the panel, which is what a
		-- load to the glass has always cost. Cutting the rows back
		-- out of the image would be a second gather for the same
		-- pixels.
		local part = onglass(img, m.r)

		if part and part.w == w and part.h == h then
			platform.load(img.at.x + x, img.at.y + y, w, h,
			    m.data, m.fmt)
		elseif part then
			shown(img, part)
		end
		return true
	end
	platform.load(x, y, w, h, m.data, m.fmt)
	return true
end

-- only where the device has a bit plane to hand back: a screenshot on
-- a 1bpp shadow otherwise costs a 32x expansion to BGRx and a repack
-- in lua. platform.unload1 is absent on a colour framebuffer.
if platform.unload1 then
	function ops.unload1(m)
		local x, y, w, h = rect(m.r)

		return platform.unload1(x, y, w, h)
	end
end

function ops.unload(m)
	local x, y, w, h = rect(m.r)

	return platform.unload(x, y, w, h)
end

-- within an image, or on the glass. A window's own scroll is what
-- keeps a terminal in one from repainting its whole grid per burst.
function ops.scroll(m, space)
	local x, y, w, h = rect(m.r)
	local to = m.to or {}
	local img = image(space, m.id)

	if img then
		img:move(m.r, { x = to.x or 0, y = to.y or 0 })

		-- and the moved pixels to the glass. Not platform.scroll:
		-- that moves the panel's own shadow, which only knows
		-- full-width rows at x=0, and a window is neither. Sending
		-- what the image now holds is what a window can do.
		shown(img, { x = to.x or 0, y = to.y or 0, w = w, h = h })
		return true
	end
	platform.scroll(x, y, to.x or 0, to.y or 0, w, h)
	return true
end

-- the pointer, drawn over whatever is on the glass.
--
-- It lives here because this task is the only writer to the screen: the
-- cursor is composited on top and repaired underneath when anything is
-- drawn where it sits, and a second proc painting it would race every
-- fill. task/mousesrv.lua reports where the pointer is and never draws,
-- which is plan 9's split between devmouse and devdraw.
--
-- x or y absent leaves that coordinate alone; `on` absent leaves the
-- visibility alone, so a move is {op="cursor", x=, y=}.
-- one value, and deliberately: the dispatch reads a second return as a
-- right to close, so a reason returned here is closed as one.
function ops.cursor(m)
	if not platform.cursor then
		return nil
	end
	return platform.cursor(m.x, m.y, m.on)
end

-- ops that can only mean the glass, so a windowed session is refused
-- them. place is here too: where a window sits is the window manager's
-- to say, and it holds an id for the image where the app does not.
local GLASS = {
	unload = true, unload1 = true, setmode = true,
	cursor = true, place = true, session = true,
}

-- a session whose client has gone: sys.hungup is sole_holder, so it is
-- true once we are the only holder left. Its images go with it, which
-- is the whole reason ids are per client.
local function reap()
	local went = false

	for i = #ports, 2, -1 do
		if sys.hungup(ports[i]) then
			sys.close(ports[i])
			table.remove(ports, i)
			table.remove(spaces, i)
			nsession = nsession - 1
			went = true
		end
	end
	-- an image is a few words of table and a los.buf of pixels, and
	-- the collector only sees the words: dropping a megabyte of them
	-- moves this heap too little to pace a step of its own.
	if went then
		collectgarbage("collect")
	end
end

while true do
	local i, m = sys.alt(ports)

	if i and type(m) == "table" then
		local space = spaces[i]
		local fn = ops[m.op]
		local reply = m.reply and m.reply.__right

		if space.win and GLASS[m.op] then
			if reply then
				sys.send(reply, { err = m.op ..
				    ": the screen is not a window's to touch" })
			end
		elseif not fn then
			if reply then
				sys.send(reply,
				    { err = "no such op: " .. tostring(m.op) })
			end
		else
			-- one pcall per message, at the boundary, exactly as
			-- lib/dev.lua describes: everything inside raises
			-- freely and the caller gets the message back as text.
			local ok, res, tmp = pcall(fn, m, space)

			if reply then
				if ok then
					sys.send(reply, { ok = res })
				else
					sys.send(reply, { err = tostring(res) })
				end
			end
			-- the session's own send right, surplus once the
			-- reply has carried a copy to the client: holding it
			-- would keep sys.hungup false for ever.
			-- a handle, or nothing. Checked rather than trusted:
			-- an op that returns a reason as its second value
			-- would otherwise have it closed as a right, and
			-- take this proc -- the whole screen -- down with it.
			if ok and type(tmp) == "number" then
				sys.close(tmp)
			end
		end

		-- a right in a message is a copy this proc owns, and
		-- sending to it does not consume it: without this every
		-- request leaks one.
		if reply then
			sys.close(reply)
		end
	end
	if nsession > 0 then
		reap()
	end
end
