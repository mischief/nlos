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

-- No los.thread: this loop has no concurrency, and on a proc with no
-- threads thread.recv is exactly the tryrecv/block below -- for which
-- it costs ~24KB resident. See task/power.lua.
local function recv(h)
	while true do
		local ok, m = sys.tryrecv(h)

		if ok then
			return m
		end
		sys.block(h)
	end
end
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

-- id -> image. Ids are handed out, never reused within a boot, so a
-- stale one is an error rather than someone else's picture.
local images = {}
local nextid = 1

-- the image an op names, or nil for the screen. Raises on an id that
-- was never given out, which is a client bug and not a blank draw.
local function image(id)
	if id == nil then
		return nil
	end

	local img = images[id]

	if not img then
		error("no such image: " .. tostring(id), 0)
	end
	return img
end

local function point(p)
	if type(p) ~= "table" then
		error("no point", 0)
	end
	return p.x or 0, p.y or 0
end

local ops = {}

function ops.alloc(m)
	local w, h = m.w or 0, m.h or 0

	if w <= 0 or h <= 0 then
		error("alloc: " .. w .. "x" .. h, 0)
	end

	local id = nextid

	nextid = nextid + 1
	images[id] = md().image(w, h, m.color, m.fmt)
	return id
end

function ops.free(m)
	images[m.id] = nil
	return true
end

function ops.mode()
	return platform.mode()
end

function ops.modes()
	return platform.modes()
end

function ops.setmode(m)
	platform.setmode(m.n)
	return true
end

function ops.fill(m)
	local x, y, w, h = rect(m.r)
	local img = image(m.id)

	if img then
		img:fill(m.r, m.color or 0)
		return true
	end
	platform.fill(x, y, w, h, m.color or 0)
	return true
end

function ops.line(m)
	local img = image(m.id)
	local x0, y0 = point(m.p0)
	local x1, y1 = point(m.p1)

	if not img then
		error("line: the screen cannot be read, so a line on it "
		    .. "would have to be repaired by the caller", 0)
	end
	img:line(md().pt(x0, y0), md().pt(x1, y1), m.thick or 1,
	    m.color or 0)
	return true
end

-- src into dst at p. dst absent is the screen, and that is the one
-- direction that reaches the panel: the pixels are here already, so it
-- is a load with nothing crossing the port.
function ops.draw(m)
	local src = image(m.src)
	local dst = image(m.dst)

	if not src then
		error("draw: no source image", 0)
	end

	local r = m.r or src:rect()
	local x, y = point(m.p or { x = r.x, y = r.y })

	if dst then
		dst:draw(md().pt(x - r.x, y - r.y), src, r)
		return true
	end
	platform.load(x, y, r.w, r.h, src:bytes(r), src.fmt)
	return true
end

-- m.fmt names what the client's bytes are; absent is bgrx. The driver
-- takes what mode() said it takes without converting, and converts
-- anything else.
function ops.load(m)
	local x, y, w, h = rect(m.r)
	local img = image(m.id)

	if img then
		local band = md().fromBytes(w, h, m.data, m.fmt)

		img:draw(md().pt(x, y), band, band:rect())
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

function ops.scroll(m)
	local x, y, w, h = rect(m.r)
	local to = m.to or {}

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
function ops.cursor(m)
	if not platform.cursor then
		return nil, "no cursor on this screen"
	end
	return platform.cursor(m.x, m.y, m.on)
end

while true do
	local m = recv(sys.SELF)
	local fn = ops[m.op]
	local reply = m.reply and m.reply.__right

	if not fn then
		if reply then
			sys.send(reply,
			    { err = "no such op: " .. tostring(m.op) })
		end
	else
		-- one pcall per message, at the boundary, exactly as
		-- lib/dev.lua describes: everything inside raises freely and
		-- the caller gets the message back as text.
		local ok, res = pcall(fn, m)

		if reply then
			if ok then
				sys.send(reply, { ok = res })
			else
				sys.send(reply, { err = tostring(res) })
			end
		end
	end

	-- a right in a message is a copy this proc owns, and sending to it
	-- does not consume it: without this every request leaks one.
	if reply then
		sys.close(reply)
	end
end
