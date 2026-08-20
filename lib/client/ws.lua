-- client/ws: the websocket task, as a client.
--
-- open() answers a socket object with the send/recv/close that
-- lib/nostrrelay.lua and anything else framed expects, so a caller
-- cannot tell this from a websocket lib/websocket.lua built over tcp.

local rpc = require("client.rpc")

local requester = rpc.requester

local M = {}

local Ws = {}

Ws.__index = Ws

function Ws:send(data)
	return self.req({ op = "send", id = self.id, data = data })
end

-- one message, or nil and why. Parks in the task until there is one:
-- the socket cannot be waited on, so somebody has to poll it, and
-- doing it there costs one thread for the machine rather than one per
-- caller.
function Ws:recv()
	return self.req({ op = "recv", id = self.id })
end

function Ws:state()
	return self.req({ op = "state", id = self.id })
end

-- the name lib/websocket.lua's socket answers to, so a caller written
-- against one works over the other unchanged.
function Ws:alive()
	return self.id ~= nil and self:state() == "open"
end

function Ws:close()
	if self.id then
		self.req({ op = "close", id = self.id })
		self.id = nil
	end
end

function M.new(handle)
	local req = requester(handle)
	local n = { handle = handle }	-- for re-granting: {__right = n.handle}

	-- open(url) -> socket, or nil and why. Answers once the peer has
	-- accepted, so a socket handed back is one that can be written to.
	function n.open(url)
		local id, why = req({ op = "open", url = url })

		if not id then
			return nil, why or "no answer"
		end
		return setmetatable({ id = id, req = req }, Ws)
	end

	return n
end

return M
