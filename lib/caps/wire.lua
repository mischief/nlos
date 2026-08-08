-- caps/wire: the 9p wire, as a client

local sys = require("los.sys")
local rpc = require("caps.rpc")

local requester = rpc.requester

local M = {}

function M.new(handle)
	local req = requester(handle)
	local w = { handle = handle }	-- for re-granting to a spawned child: {__right = w.handle}

	function w.write(data)
		sys.send(handle, { op = "write", data = data })
	end
	function w.read()
		return req({ op = "read" })
	end
	return w
end

return M
