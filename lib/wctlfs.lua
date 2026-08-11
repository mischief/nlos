-- wctlfs: whether an app is the one in front, as a file.
--
--	/dev/wctl	read: "visible", "hidden" or "redraw", one line

-- A read blocks until the answer changes, so an app's loop is a read
-- rather than a poll, and the same idiom as reading the mouse. The
-- first read answers at once, so an app that has just started learns
-- where it stands without waiting to be switched.

-- The framebuffer keeps an app's window, so switching loses no pixels.
-- "hidden" is an invitation to stop: what an app draws while hidden is
-- cycles and messages spent on pixels nobody sees. "visible" says it
-- may start again, and finds its picture where it left it.

-- "redraw" is the one that costs: the window's pixels are gone and the
-- app must paint from its own state. It follows a shape change, or a
-- window the system could not keep -- so it is said only when true.
-- bin/scribble.lua, which keeps no state, comes back empty.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")

local M = {}

-- new(visible) -> { show = function(bool), lost = function(),
--		     state = function(), backend = <dev backend> }
function M.new()
	-- a new window has no pixels in it, so the first thing any app is
	-- told is to paint them, whether or not it is on the glass yet.
	local state = "redraw"
	local seq = 0
	local waiters = {}
	local self = {}

	local function say(want)
		state = want
		seq = seq + 1
		for _, w in ipairs(waiters) do
			sys.send(w.reply, { seq = seq, state = state })
		end
		waiters = {}
	end

	function self.show(on)
		local want = on and "visible" or "hidden"

		-- only a change is an event: an app told twice would act
		-- twice on one switch
		if want ~= state then
			say(want)
		end
	end

	-- the window's pixels are gone, so the app must paint them again.
	-- Always an event, even to an app that already thinks it is
	-- visible, because what changed is the window and not the focus.
	function self.lost()
		say("redraw")
	end

	function self.state()
		return state
	end

	local B = {}

	local function isroot(h)
		return h.path == "/"
	end

	function B.attach()
		return { path = "/" }
	end

	function B.walk(h, name)
		if name == "." or name == ".." then
			return { path = h.path }
		end
		if not isroot(h) or name ~= "wctl" then
			dev.error(dev.Enonexist)
		end
		return { path = "/wctl" }
	end

	function B.stat(h)
		if isroot(h) then
			return { name = "/", size = 0, dir = true }
		end
		return { name = "wctl", size = #state + 1, dir = false }
	end

	function B.open(h, mode)
		if mode and mode ~= "r" then
			dev.error(dev.Eperm)
		end
		if isroot(h) then
			return { path = h.path }
		end
		-- seen one behind, so the first read answers now
		return { path = h.path, seen = seq - 1 }
	end

	function B.read(h, off, n)
		if isroot(h) then
			dev.error(dev.Eisdir)
		end
		if h.seen ~= seq then
			h.seen = seq
			return (state .. "\n"):sub(1, n)
		end

		local rp = sys.newport("wctlfs.rp")

		waiters[#waiters + 1] = { reply = rp }

		local m = thread.recv(rp)

		sys.close(rp)
		if type(m) == "table" and m.gone then
			dev.error(dev.Ehungup)
		end
		if type(m) ~= "table" or type(m.state) ~= "string" then
			dev.error(dev.Eio .. ": woken with no state")
		end
		h.seen = m.seq
		return (m.state .. "\n"):sub(1, n)
	end

	-- released rather than left parked: the state a waiter wants
	-- comes from the client that has just gone.
	function B.hangup()
		local w = waiters

		waiters = {}
		for _, x in ipairs(w) do
			sys.send(x.reply, { gone = true })
		end
	end

	function B.readdir(h)
		if not isroot(h) then
			dev.error(dev.Enotdir)
		end
		return { { name = "wctl", size = #state + 1, dir = false } }
	end

	-- read-only. Plan 9's wctl is written to, to move and resize a
	-- window; there is one shape of window here and an app does not
	-- choose it.
	function B.create()
		dev.error(dev.Eperm)
	end

	function B.write()
		dev.error(dev.Eperm)
	end

	function B.clunk()
	end

	self.backend = B
	return self
end

return M
