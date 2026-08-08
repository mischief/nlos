-- client/dns: the resolver, as a client

local rpc = require("client.rpc")

local requester = rpc.requester

-- dns is an ordinary spawned proc rather than a kernel-registered
-- exclusive task (see lib/dns.lua), so it never appears in
-- sys.granted() at all -- its handle is simply whatever sys.spawn
-- returned.
local M = {}

function M.new(handle)
	local req = requester(handle)
	local d = { handle = handle }

	function d.resolve(name)
		return req({ op = "resolve", name = name })
	end
	return d
end

return M
