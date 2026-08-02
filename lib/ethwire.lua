-- an eth capability, as the `wire` the protocol modules take.
--
-- lib/arp.lua (and the ip layer above it) do not know how to reach a
-- device: they take a table of send, recv, now and yield, so the same
-- codec can run against a real nic, a test harness or another guest.
-- This is the binding for the real thing.
--
-- recv_wait is the one that matters. It parks the request inside the
-- eth task and returns when a frame arrives or the deadline passes,
-- which means the machine can halt in between instead of spinning
-- through a poll loop -- see kernel.c's pump_eth and lib/eth.lua.
--
-- One outstanding wait, reused. A timed-out wait is still parked in the
-- eth task, so issuing a second would leave the first stranded there
-- forever, holding a reply right; instead the same request is waited on
-- again next time round. That is why the reply port is owned by this
-- object rather than made fresh per call.

local sys = require("los.sys")
local thread = require("los.thread")

local ethwire = {}

function ethwire.new(cap)
	local w = { cap = cap }

	-- a private port for the ordinary request/reply calls, and a
	-- second one dedicated to the parked receive, so a reply to a
	-- send() cannot be mistaken for the frame a wait is holding out
	-- for.
	local rpcport = sys.newport()
	local waitport = sys.newport()
	local parked = false

	local function rpc(msg)
		msg.reply = { __right = sys.sendright(rpcport) }
		sys.send(cap, msg)
		return thread.recv(rpcport)
	end

	w.rpc = rpc

	function w.mac()
		local r = rpc({ op = "mac" })

		return r and r.mac
	end

	function w.send(frame)
		local r = rpc({ op = "send", data = frame })

		return r and r.ok
	end

	function w.recv()
		local r = rpc({ op = "recv" })

		return r and r.data
	end

	function w.irqs()
		local r = rpc({ op = "irqs" })

		return r and r.n
	end

	-- wait up to ms for a frame. nil if none came in that time, with
	-- the request left parked for the next call to wait on again.
	function w.recv_wait(ms)
		if not parked then
			sys.send(cap, { op = "recv", wait = true,
			    reply = { __right = sys.sendright(waitport) } })
			parked = true
		end

		local m = thread.recvtimeout(waitport, ms or 1000)

		if not m then
			return nil		-- still parked; ask again later
		end
		parked = false
		return m.data
	end

	w.now = sys.uptime_ms
	w.yield = sys.yield

	return w
end

return ethwire
