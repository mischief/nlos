-- mousesrv: the pointer, as /dev/mouse.
--
-- plan 9's devmouse, in a proc. The kernel holds the device and pushes
-- one record per change onto a port; this holds the receive right to
-- that port and serves the records as a file, so a program reaches the
-- pointer through its namespace rather than through a capability it had
-- to be handed.
--
-- That is the whole reason this proc exists. A right must be lent by
-- every layer between the machine and a program; a mount travels in a
-- namespace description on its own, and dev.subtree can hand a session
-- the pointer and nothing else.
--
-- ---- the file ----
--
--	/dev/mouse	read: one record, 49 bytes
--
-- The record is plan 9's, unchanged: 'm' then four fixed-width fields,
-- x, y, buttons and a millisecond clock. Fixed width so a reader asks
-- for 49 bytes and gets exactly one event, with no framing rule of its
-- own. Buttons are a bitmask -- 1, 2 and 4 for the buttons, 8 and 16
-- for a wheel -- and a device with one contact reports 1 or 0.
--
-- ---- a read blocks, and coalesces ----
--
-- A read waits for the pointer to move and answers with where it is
-- now, not with every place it has been. That is the property worth
-- having: a client that redraws slowly falls behind in resolution
-- rather than in time, and never chases a cursor through a queue of
-- stale positions. The kernel's pump coalesces for the same reason, so
-- nothing here has to undo a backlog.
--
-- A reader that has not yet seen the current position gets it at once;
-- one that is up to date waits.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local srv = require("srv")

local job = ... or thread.recv(sys.SELF)
local ptr = job.ptr and job.ptr.__right

if not ptr then
	print("mousesrv: no pointer capability")
	return
end

-- the latest record, and a counter that says which one it is. A reader
-- compares the counter it last saw rather than the record itself: two
-- identical positions a second apart are two events, and a client
-- watching for a button release must see the second.
local latest = string.format("m%11d %11d %11d %11d", 0, 0, 0, 0)
local seq = 0
local waiters = {}

-- wheel clicks waiting to be read.
--
-- The position may be coalesced and a click may not. A finger's old
-- positions are of no use to a reader that fell behind, but a scroll it
-- never saw is scrolling that did not happen -- so a record carrying
-- button 8 or 16 queues here and is handed over one at a time, while
-- ordinary motion just overwrites `latest`.
--
-- Bounded, because a queue that never drops is a leak with better
-- manners: a reader that has stopped reading should cost a spin of the
-- ball, not the machine.
local WHEELMAX = 32
local wheelq = {}

local function iswheel(rec)
	local b = tonumber(rec:match("^m%s*%-?%d+%s+%-?%d+%s+(%-?%d+)"))

	return b and (b & 24) ~= 0
end

-- the fb task, where the machine has a screen. The cursor belongs to
-- whoever owns the glass -- it is drawn over what is already there and
-- repaired from the shadow when anything moves under it -- so this
-- proc reports a position and never draws.
local fb = job.fb and job.fb.__right

thread.spawn(function()
	while true do
		local rec = thread.recv(ptr)

		if type(rec) == "string" then
			if iswheel(rec) then
				if #wheelq < WHEELMAX then
					wheelq[#wheelq + 1] = rec
				end
			else
				latest = rec
			end
			seq = seq + 1

			-- the cursor follows the finger without a client in
			-- the loop, which is what keeps it on the finger
			-- rather than a round trip behind it. A wheel
			-- record carries the position it scrolled at and
			-- does not move anything, so it is not a move.
			if fb and not iswheel(rec) then
				local x, y = rec:match(
				    "^m%s*(%-?%d+)%s+(%-?%d+)")

				-- on every move, not once at the start: the
				-- cursor is hidden until something says to
				-- show it, and a move alone deliberately
				-- leaves the visibility as it found it. A
				-- machine with a pointer shows where it is.
				if x then
					sys.send(fb, { op = "cursor",
					    x = tonumber(x),
					    y = tonumber(y), on = true })
				end
			end

			if #wheelq > 0 then
				-- one click to one reader: two clicks must
				-- not wake two readers with the same one,
				-- and a click nobody took stays queued.
				while #waiters > 0 and #wheelq > 0 do
					local w = table.remove(waiters, 1)

					sys.send(w.reply, { seq = seq,
					    rec = table.remove(wheelq, 1) })
				end
			else
				-- a position is shared: every reader wants
				-- the same answer, which is where it is now.
				for _, w in ipairs(waiters) do
					sys.send(w.reply,
					    { seq = seq, rec = latest })
				end
				waiters = {}
			end
		end
	end
end)

-- what a reader should be given next: a queued wheel click if there is
-- one, otherwise where the pointer is. Clicks come out in order and
-- exactly once; the position is whatever it is now.
local function nextrec()
	if #wheelq > 0 then
		return table.remove(wheelq, 1)
	end
	return latest
end

-- the backend: one file, and reading it is the whole protocol.
local function backend()
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
	-- failure either can detect: both look like a mouse that
	-- stutters. Refusing the second open turns it into an error with
	-- a name, which is why plan 9's mouse is exclusive too.
	--
	-- Held by the handle rather than counted, so a program that dies
	-- without closing still frees it: the server clunks every fid of
	-- a session that goes away.
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
		-- a handle of its own, as every other backend's open
		-- returns: the walked one may be shared and the open one
		-- carries state.
		--
		-- seen is the sequence it opened at, so the first read
		-- answers with the current position rather than waiting
		-- for the pointer to move. A program that opens the mouse
		-- wants to know where it is.
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

		local rp = sys.newport()

		waiters[#waiters + 1] = { reply = rp }

		local m = thread.recv(rp)

		sys.close(rp)
		if type(m) ~= "table" then
			return ""
		end
		h.seen = m.seq
		return tostring(m.rec):sub(1, n)
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

	return B
end

srv.main(backend)
