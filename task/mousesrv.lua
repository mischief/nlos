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
-- The file itself is lib/mousefs.lua, which is also what bin/dio.lua
-- serves to an app: what is here is the half that touches the hardware
-- -- the pointer port, and the cursor that follows it.

local sys = require("los.sys")
local thread = require("los.thread")
local mousefs = require("mousefs")
local srv = require("srv")

local job = ... or thread.recv(sys.SELF)
local ptr = job.ptr and job.ptr.__right

if not ptr then
	print("mousesrv: no pointer capability")
	return
end

-- the fb task, where the machine has a screen. The cursor belongs to
-- whoever owns the glass -- it is drawn over what is already there and
-- repaired from the shadow when anything moves under it -- so this proc
-- reports a position and never draws.
local fb = job.fb and job.fb.__right
local mouse = mousefs.new()

thread.spawn(function()
	while true do
		local rec = thread.recv(ptr)

		if type(rec) == "string" then
			-- the cursor follows the finger without a client in
			-- the loop, which is what keeps it on the finger
			-- rather than a round trip behind it. A wheel record
			-- carries the position it scrolled at and does not
			-- move anything, so it is not a move.
			if fb and not mousefs.iswheel(rec) then
				local x, y = mousefs.parse(rec)

				-- on every move, not once at the start: the
				-- cursor is hidden until something says to
				-- show it, and a move alone deliberately
				-- leaves the visibility as it found it. A
				-- machine with a pointer shows where it is.
				if x then
					sys.send(fb, { op = "cursor", x = x,
					    y = y, on = true })
				end
			end
			mouse.post(rec)
		end
	end
end)

srv.main(function()
	return mouse.backend
end)
