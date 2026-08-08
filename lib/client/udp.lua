-- client/udp: the udp task, as a client

local sys = require("los.sys")
local rpc = require("client.rpc")

local requester = rpc.requester

local M = {}

function M.new(handle)
	local req = requester(handle)
	local u = { handle = handle }	-- for re-granting to a spawned child: {__right = u.handle}

	-- connectionless: no listen/accept/dial, every send names its
	-- destination, every recv reports the sender's.
	function u.open(port, raw)
		return req({ op = "open", port = port, raw = raw })
	end
	function u.send(connid, a, b, c, d, port, data)
		return req({ op = "send", connid = connid,
		    a = a, b = b, c = c, d = d, port = port, data = data })
	end
	function u.recv(connid, maxlen)
		return req({ op = "recv", connid = connid,
		    maxlen = maxlen or 4096 })
	end
	function u.close(connid)
		-- fire-and-forget, same reasoning as tcp's close above.
		sys.send(handle, { op = "close", connid = connid })
	end
	function u.cancel(connid)
		-- fire-and-forget: aborts an outstanding op on connid
		-- without closing it -- see lib/udp.lua's op table comment.
		sys.send(handle, { op = "cancel", connid = connid })
	end
	return u
end

return M
