-- mouse: the pointer as a queue of records, on both sides of it.
--
-- A record is plan 9's: 'm', then x, y, buttons and a millisecond
-- clock, each twelve wide. The kernel's pointer port carries these and
-- so does the port a window system pushes to, so a reader is a recv and
-- a parse wherever it reads from.
--
-- An app in a window takes them on the port its keys already arrive on,
-- and tells a record from a keystroke by parsing it.

local sys = require("los.sys")

local M = {}

-- Buttons: 1, 2 and 4 are buttons, 8 and 16 a wheel. A device with one
-- contact reports 1 or 0. plan 9 names no bits for a second wheel axis,
-- so the horizontal pair follows x11's buttons 6 and 7.
M.WHEELUP = 8
M.WHEELDOWN = 16
M.WHEELLEFT = 32
M.WHEELRIGHT = 64

function M.format(x, y, b, ms)
	return ("m%12d%12d%12d%12d"):format(x, y, b, ms or sys.uptime_ms())
end

function M.parse(rec)
	if type(rec) ~= "string" then
		return nil
	end

	local x, y, b, ms = rec:match(
	    "^m%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")

	if not x then
		return nil
	end
	return tonumber(x), tonumber(y), tonumber(b), tonumber(ms)
end

M.WHEEL = M.WHEELUP | M.WHEELDOWN | M.WHEELLEFT | M.WHEELRIGHT

function M.iswheel(rec)
	local _, _, b = M.parse(rec)

	return b ~= nil and (b & M.WHEEL) ~= 0
end

-- ---- the half that has the pointer ----

-- What a queue holds before the reader is declared too far behind to
-- care about the rest. Motion coalesces, so this fills only with
-- button and wheel events, which are the ones that must not be lost.
local QMAX = 16

-- One client's queue. What its port will not take now waits here for
-- the next post.
--
-- Motion coalesces by replacing the tail, so a slow reader falls behind
-- in resolution rather than in time. A change of button never
-- coalesces: a click nobody saw is a click that did not happen.
function M.queue(send)
	local q = {}
	local last = 0		-- buttons, as last queued
	local self = {}

	local function flush()
		while #q > 0 do
			if not sys.send(send, q[1]) then
				return false
			end
			table.remove(q, 1)
		end
		return true
	end

	function self.post(x, y, b, ms)
		local rec = M.format(x, y, b, ms)

		if #q > 0 and b == last then
			q[#q] = rec	-- motion, superseded
		elseif #q < QMAX then
			q[#q + 1] = rec
		end
		last = b
		flush()
	end

	-- offered again, for a port that was full when it was first
	-- tried. A caller with nothing else to do calls this.
	function self.retry()
		return flush()
	end

	function self.pending()
		return #q
	end
	return self
end

-- ---- the half that reads it ----

-- read() blocks and answers x, y, buttons and the clock. It holds
-- nothing: the port is the queue, and the record is the whole event.
function M.reader(handle)
	local thread = require("los.thread")
	local self = {}

	function self.read()
		while true do
			local rec, why = thread.await(handle)

			if why then
				return nil, "pointer hung up"
			end

			local x, y, b, ms = M.parse(rec)

			if x then
				return x, y, b, ms
			end
		end
	end
	return self
end

return M
