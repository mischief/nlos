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

local ops = {}

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

	platform.fill(x, y, w, h, m.color or 0)
	return true
end

function ops.load(m)
	local x, y, w, h = rect(m.r)

	platform.load(x, y, w, h, m.data)
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
