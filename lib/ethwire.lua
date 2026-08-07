-- an eth capability, as the `wire` the protocol modules take.
--
-- lib/arp.lua (and the ip layer above it) do not know how to reach a
-- device: they take a table of send, recv, now and yield, so the same
-- codec can run against a real nic, a test harness or another guest.
-- This is the binding for the real thing.
--
-- Frames arrive by themselves. new() hands the eth task a right to a
-- port of its own, and from then on every frame is pushed into it;
-- recv_wait is an ordinary receive on that port, so the machine still
-- halts between frames -- see kernel.c's pump_eth and task/eth.lua.
--
-- Registering in new(), before the caller can have sent anything, is
-- the point rather than a detail. Doing it lazily on the first
-- recv_wait would put the registration after the caller's first send,
-- which is precisely the window that loses the reply to it: a ping
-- goes out, the answer comes back in microseconds, and the listener
-- does not exist yet.

local sys = require("los.sys")
local thread = require("los.thread")
local buf = require("los.buf")

local ethwire = {}

function ethwire.new(cap)
	local w = { cap = cap }

	-- the ordinary calls go through thread.rpc, which owns minting and
	-- closing the reply right. Writing that out here is what exhausted
	-- MAXRIGHTS partway through a DHCP exchange, and it is the third
	-- time this tree has made that mistake; see thread.rpc.
	--
	-- frames land here, and only frames: a port of its own so a reply
	-- to a send() cannot be mistaken for an arriving frame.
	local framePort = sys.newport("ethwire.framePo")

	local function rpc(msg)
		return thread.rpc(cap, msg)
	end

	w.rpc = rpc

	function w.mac()
		local r = rpc({ op = "mac" })

		return r and r.mac
	end

	-- a frame built here is ours, so it is handed to the driver rather
	-- than copied into the message and out again as a string. One a
	-- caller passed straight through is not ours to give.
	function w.send(frame)
		local r = rpc({ op = "send",
		    data = buf.is(frame) and frame:movable() and
		        { __buf = frame } or frame })

		return r and r.ok
	end

	function w.irqs()
		local r = rpc({ op = "irqs" })

		return r and r.n
	end

	-- wait up to ms for a frame, nil if none came in that time.
	function w.recv_wait(ms)
		local m = thread.recvtimeout(framePort, ms or 1000)

		return m and m.data
	end

	-- the frame port itself, for a task that alts between the wire and
	-- its own clients rather than blocking on the wire. Such a task
	-- must not register a second listener of its own: that would cost
	-- a copy of every frame to a port nobody drains.
	w.port = framePort

	w.now = sys.uptime_ms
	w.yield = sys.yield

	-- register before returning, so a caller cannot send anything
	-- before the wire is listening. The right is copied into the
	-- message rather than moved, so ours is closed straight after --
	-- see thread.rpc for the count this tree has already run out of.
	local right = sys.sendright(framePort)
	local r = rpc({ op = "listen", port = { __right = right } })

	sys.close(right)
	if not (r and r.ok) then
		return nil, "eth refused a listen"
	end

	return w
end

return ethwire
