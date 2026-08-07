-- mousefs: the pointer as a file, with no device under it.
--
-- The file half of plan 9's devmouse, separated from whatever produces
-- the records. task/mousesrv.lua feeds it from the kernel's pointer
-- port; bin/dio.lua feeds it records it has already moved into an app's
-- coordinates. Both serve the same file, so a program cannot tell which
-- it is reading, and that is what lets a window system exist without
-- every program learning about windows.
--
--	/dev/mouse	read: one record, 49 bytes
--
-- The record is plan 9's: 'm' then four fixed-width fields, x, y,
-- buttons and a millisecond clock. Fixed width so a reader asks for 49
-- bytes and gets exactly one event, with no framing rule of its own.
-- Buttons are a bitmask -- 1, 2 and 4 for the buttons, 8 and 16 for a
-- wheel -- and a device with one contact reports 1 or 0.
--
-- ---- a read blocks, and coalesces ----
--
-- A read waits for the pointer to move and answers with where it is
-- now, not with every place it has been. A client that redraws slowly
-- falls behind in resolution rather than in time, and never chases a
-- cursor through a queue of stale positions.
--
-- A wheel click is the exception, and queues. A finger's old positions
-- are of no use to a reader that fell behind, but a scroll it never saw
-- is scrolling that did not happen.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")

local M = {}

-- 'm' and four fields of twelve: a space and eleven digits, which is
-- plan 9's record and exactly 49 bytes. The width is the whole framing
-- rule -- a reader asks for 49 and has one event -- so a record of any
-- other size is a bug in this file rather than a detail.
local RECLEN = 49

M.RECLEN = RECLEN

local function record(x, y, b, ms)
	return string.format("m%12d%12d%12d%12d", x, y, b, ms)
end

local ZERO = record(0, 0, 0, 0)

assert(#ZERO == RECLEN, "the mouse record is not 49 bytes")

-- the fields of a record, as numbers. nil for anything that is not one.
function M.parse(rec)
	if type(rec) ~= "string" then
		return nil
	end

	local x, y, b = rec:match("^m%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")

	if not x then
		return nil
	end
	return tonumber(x), tonumber(y), tonumber(b)
end

function M.format(x, y, b, ms)
	return record(x, y, b, ms or sys.uptime_ms())
end

function M.iswheel(rec)
	local _, _, b = M.parse(rec)

	return b ~= nil and (b & 24) ~= 0
end

-- new() -> { post = function(rec), backend = <dev backend> }
--
-- post takes one record from wherever the caller gets records; backend
-- is what srv.serve is given.
--
-- Bounded, because a queue that never drops is a leak with better
-- manners: a reader that has stopped reading should cost a spin of the
-- ball, not the machine.
local WHEELMAX = 32

function M.new()
	local latest = ZERO
	local seq = 0
	local waiters = {}
	local wheelq = {}
	local self = {}

	function self.post(rec)
		if type(rec) ~= "string" then
			return
		end
		if M.iswheel(rec) then
			if #wheelq < WHEELMAX then
				wheelq[#wheelq + 1] = rec
			end
		else
			latest = rec
		end
		-- a counter rather than the record itself: two identical
		-- positions a second apart are two events, and a client
		-- watching for a button release must see the second.
		seq = seq + 1

		if #wheelq > 0 then
			-- one click to one reader: two clicks must not wake
			-- two readers with the same one, and a click nobody
			-- took stays queued.
			while #waiters > 0 and #wheelq > 0 do
				local w = table.remove(waiters, 1)

				sys.send(w.reply, { seq = seq,
				    rec = table.remove(wheelq, 1) })
			end
		else
			-- a position is shared: every reader wants the same
			-- answer, which is where it is now.
			for _, w in ipairs(waiters) do
				sys.send(w.reply, { seq = seq, rec = latest })
			end
			waiters = {}
		end
	end

	function self.latest()
		return latest
	end

	local function nextrec()
		if #wheelq > 0 then
			return table.remove(wheelq, 1)
		end
		return latest
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
		if not isroot(h) or name ~= "mouse" then
			dev.error(dev.Enonexist)
		end
		return { path = "/mouse" }
	end

	function B.stat(h)
		if isroot(h) then
			return { name = "/", size = 0, dir = true }
		end
		return { name = "mouse", size = #latest, dir = false }
	end

	-- one reader at a time.
	--
	-- Two programs reading this would each get some of a drag and
	-- neither would get all of it -- a stroke split between them, a
	-- button press seen by whichever asked first. That is not a
	-- failure either can detect: both look like a mouse that stutters.
	-- Refusing the second open turns it into an error with a name,
	-- which is why plan 9's mouse is exclusive too.
	--
	-- Held by the handle rather than counted, so a program that dies
	-- without closing still frees it: the server clunks every fid of a
	-- session that goes away.
	local owner = nil

	function B.open(h, mode)
		if mode and mode ~= "r" then
			dev.error(dev.Eperm)
		end
		if isroot(h) then
			return { path = h.path }
		end
		if owner then
			dev.error("mouse in use")
		end
		-- seen is the sequence it opened at, so the first read
		-- answers with the current position rather than waiting for
		-- the pointer to move. A program that opens the mouse wants
		-- to know where it is.
		local fh = { path = h.path, seen = seq - 1, reader = true }

		owner = fh
		return fh
	end

	-- read blocks until there is something this handle has not seen.
	-- The offset is ignored: this is a device and not a file with a
	-- position in it, exactly as plan 9's is.
	function B.read(h, off, n)
		if isroot(h) then
			dev.error(dev.Eisdir)
		end
		if #wheelq > 0 or h.seen ~= seq then
			h.seen = seq
			return nextrec():sub(1, n)
		end

		local rp = sys.newport("mousefs.rp")

		waiters[#waiters + 1] = { reply = rp }

		local m = thread.recv(rp)

		sys.close(rp)
		-- a wakeup that carries no record is a failure of this
		-- server, and it has to be said. An empty read looks to a
		-- client exactly like a record it cannot parse, and a
		-- client that treats that as end of input exits without a
		-- word -- which is the worst of the three ways this can go.
		if type(m) ~= "table" or type(m.rec) ~= "string" then
			dev.error(dev.Eio .. ": woken with no record")
		end
		h.seen = m.seq
		return m.rec:sub(1, n)
	end

	function B.readdir(h)
		if not isroot(h) then
			dev.error(dev.Enotdir)
		end
		return { { name = "mouse", size = #latest, dir = false } }
	end

	-- read-only: a write would be plan 9's cursor warp, and this
	-- machine has no cursor to warp that is not the finger's.
	function B.create()
		dev.error(dev.Eperm)
	end

	function B.write()
		dev.error(dev.Eperm)
	end

	function B.clunk(h)
		if h and h.reader and owner == h then
			owner = nil
		end
	end

	self.backend = B
	return self
end

return M
