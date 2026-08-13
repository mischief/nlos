-- mouse: the pointer as a port, on both sides of it.
--
--	request	{ seen = <sequence>, reply = {__right=} }
--	answer	{ t = "ptr", seq =, x =, y =, b =, ms = }
--
-- The answer is tagged because the reply right need not name a port of
-- its own: an app in a window points it at the port its keys and window
-- state already arrive on, and then one recv is its whole input.

-- A read blocks until the pointer has done something the asker has not
-- seen, and answers with where it is now rather than every place it has
-- been. A client that redraws slowly falls behind in resolution and not
-- in time, so it never chases a cursor through stale positions.

-- A wheel click is the exception and queues, one to one reader. A
-- finger's old positions are no use to a reader that fell behind; a
-- scroll it never saw is scrolling that did not happen.

-- `seen` belongs to the client here rather than to a file handle, which
-- is the whole difference from a served file: no session, no fid, and
-- nothing to hold exclusively.

local sys = require("los.sys")
local thread = require("los.thread")

local M = {}

-- Buttons: 1, 2 and 4 are buttons, 8 and 16 a wheel. A device with one
-- contact reports 1 or 0.
M.WHEELUP = 8
M.WHEELDOWN = 16

-- what the kernel's pointer port carries: plan 9's record, 'm' and four
-- fields of twelve. Kept because that is the wire, not because anything
-- above this file has to see it.
local RECLEN = 49

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

function M.iswheel(rec)
	local _, _, b = M.parse(rec)

	return b ~= nil and (b & (M.WHEELUP | M.WHEELDOWN)) ~= 0
end

-- ---- the half that has the pointer ----

-- post() takes a position; serve() answers the requests that arrive on
-- a port. Whoever holds the pointer runs both.
local WHEELMAX = 16

function M.server()
	local latest = { x = 0, y = 0, b = 0, ms = 0 }
	local seq = 0
	local waiters = {}
	local wheelq = {}
	local self = {}

	-- Every waiter answered here is closed: sending copies the right
	-- rather than handing it over, so the server's own copy is still
	-- its own to drop. Left open, a drag leaks one right an event.
	function self.post(x, y, b, ms)
		local ev = { x = x, y = y, b = b, ms = ms or sys.uptime_ms() }

		if (b & (M.WHEELUP | M.WHEELDOWN)) ~= 0 then
			if #wheelq < WHEELMAX then
				wheelq[#wheelq + 1] = ev
			end
		else
			latest = ev
		end
		-- a counter rather than the position: two identical
		-- positions a second apart are two events, and a client
		-- watching for a release must see the second.
		seq = seq + 1

		if #wheelq > 0 then
			-- one click to one reader, and a click nobody took
			-- stays queued
			while #waiters > 0 and #wheelq > 0 do
				local w = table.remove(waiters, 1)
				local ev2 = table.remove(wheelq, 1)

				sys.send(w, { t = "ptr", seq = seq, x = ev2.x,
				    y = ev2.y, b = ev2.b, ms = ev2.ms })
				sys.close(w)
			end
		else
			for _, w in ipairs(waiters) do
				sys.send(w, { t = "ptr", seq = seq, x = latest.x,
				    y = latest.y, b = latest.b,
				    ms = latest.ms })
				sys.close(w)
			end
			waiters = {}
		end
	end

	-- one request. Answers now where the asker is behind, and parks
	-- the reply right where it is not.
	function self.ask(m)
		local reply = type(m) == "table" and m.reply and
		    m.reply.__right

		if not reply then
			return
		end
		if (m.seen or -1) ~= seq then
			local ev = latest

			if #wheelq > 0 then
				ev = table.remove(wheelq, 1)
			end
			sys.send(reply, { t = "ptr", seq = seq, x = ev.x, y = ev.y,
			    b = ev.b, ms = ev.ms })
			sys.close(reply)
			return
		end
		waiters[#waiters + 1] = reply
	end

	-- everyone parked here is told the pointer has gone, so a reader
	-- fails rather than waiting for a machine that stopped answering.
	function self.hangup()
		for _, w in ipairs(waiters) do
			sys.send(w, { t = "ptr", gone = true })
			sys.close(w)
		end
		waiters = {}
	end

	function self.serve(port)
		while true do
			local m, why = thread.await(port)

			if why then
				break
			end
			self.ask(m)
		end
		self.hangup()
	end
	return self
end

-- ---- the half that reads it ----

-- read() blocks and answers x, y, buttons. The sequence it last saw is
-- kept here, so a program holds nothing but the right.
function M.reader(handle)
	local seen = -1
	local self = {}

	function self.read()
		local rp = sys.newport("mouse.reply")
		local send = sys.sendright(rp)
		local ok = sys.send(handle, { seen = seen,
		    reply = { __right = send } })

		if not ok then
			sys.close(send)
			sys.close(rp)
			return nil, "no pointer"
		end

		local m = thread.recv(rp)

		sys.close(send)
		sys.close(rp)
		if type(m) ~= "table" or m.gone then
			return nil, "pointer hung up"
		end
		seen = m.seq
		return m.x, m.y, m.b, m.ms
	end
	return self
end

-- the same protocol, answered onto a port the caller already has, so a
-- program whose keys arrive there needs no thread to read the pointer.
-- The caller owns the loop; this owns the sequence.
--
-- arm() again after each took(): that one outstanding request is the
-- credit that makes the server collapse motion rather than queue it.
function M.onport(handle, ev)
	local self = { seen = -1 }

	-- our copy goes after the send: a right is copied by being sent,
	-- and keeping this one costs a right per event.
	function self.arm()
		local sr = sys.sendright(ev)
		local ok = sys.send(handle, { seen = self.seen,
		    reply = { __right = sr } })

		sys.close(sr)
		return ok
	end

	-- record what arrived, and say whether the pointer is still there.
	function self.took(m)
		if type(m) ~= "table" or m.gone then
			return false
		end
		self.seen = m.seq
		return true
	end
	return self
end

return M
