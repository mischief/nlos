-- wctlfs: whether an app is the one in front, as a file.
--
--	/dev/wctl	read: "redraw" or "hidden", one line
--
-- A read blocks until the answer changes, so an app's loop is a read
-- rather than a poll, and the same idiom as reading the mouse. A window
-- system that sent a message to the app's mailbox instead would be the
-- one place it spoke a language the rest of the machine does not.
--
-- ---- redraw means redraw ----
--
-- An app keeps no pixels here. When it comes to the front it is told to
-- draw itself again, from what it knows, onto an area that has been
-- cleared. That is the whole bargain: no backbuffer per app, nothing to
-- restore, and a board that has 4MB does not spend it on copies of a
-- screen it is not showing.
--
-- The cost is that an app must be able to draw itself from its own
-- state. An app with no state -- bin/scribble.lua, whose picture is
-- only ever on the glass -- comes back empty, and that is honest rather
-- than a bug to work around with memory the machine has not got.
--
-- The first read answers at once with the current state, so an app that
-- has just started learns where it stands without waiting to be
-- switched.
--
-- One word covers a shape change too: an app told to redraw asks the
-- framebuffer for its mode and paints what it gets. There is one window
-- shape today, and an app written this way needs nothing new when there
-- is more than one.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")

local M = {}

-- new(visible) -> { show = function(bool), backend = <dev backend> }
function M.new(visible)
	local state = visible ~= false and "redraw" or "hidden"
	local seq = 0
	local waiters = {}
	local self = {}

	function self.show(on)
		local want = on and "redraw" or "hidden"

		-- an app told twice is an app that redraws twice, so only a
		-- change is an event
		if want == state then
			return
		end
		state = want
		seq = seq + 1
		for _, w in ipairs(waiters) do
			sys.send(w.reply, { seq = seq, state = state })
		end
		waiters = {}
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

		local rp = sys.newport()

		waiters[#waiters + 1] = { reply = rp }

		local m = thread.recv(rp)

		sys.close(rp)
		if type(m) ~= "table" or type(m.state) ~= "string" then
			dev.error(dev.Eio .. ": woken with no state")
		end
		h.seen = m.seq
		return (m.state .. "\n"):sub(1, n)
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
