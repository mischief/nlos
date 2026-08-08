-- client/tcp: the tcp task, as a client

local sys = require("los.sys")
local rpc = require("client.rpc")

local requester = rpc.requester

local M = {}

function M.new(handle)
	local req = requester(handle)
	local n = { handle = handle }	-- for re-granting to a spawned child: {__right = n.handle}

	-- the NIC's own MAC, which a dhcp client needs for chaddr.
	function n.hwaddr()
		return req({ op = "hwaddr" })
	end

	-- install a static address: what a lua dhcp client calls once it has
	-- a lease, and what stops the firmware's own dhcp dead.
	function n.setaddr(a, b, c, d, ma, mb, mc, md, ga, gb, gc, gd)
		return req({ op = "setaddr", a = a, b = b, c = c, d = d,
		    ma = ma, mb = mb, mc = mc, md = md,
		    ga = ga, gb = gb, gc = gc, gd = gd })
	end
	function n.listen(port)
		return req({ op = "listen", port = port })
	end
	function n.dial(a, b, c, d, port)
		return req({ op = "dial", a = a, b = b, c = c, d = d,
		    port = port })
	end
	function n.accept(connid)
		return req({ op = "accept", connid = connid })
	end
	function n.send(connid, data)
		return req({ op = "send", connid = connid, data = data })
	end
	function n.recv(connid, maxlen)
		return req({ op = "recv", connid = connid,
		    maxlen = maxlen or 4096 })
	end
	function n.close(connid)
		-- fire-and-forget: tcp.lua's "close" op never replies (see
		-- its own header comment) -- going through req() here would
		-- deadlock forever waiting on a reply that never comes,
		-- exactly the bug fixed earlier this session.
		sys.send(handle, { op = "close", connid = connid })
	end
	return n
end

return M
