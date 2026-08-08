-- caps/power: reset and stall, as a client

local sys = require("los.sys")

local M = {}

function M.new(handle)
	local p = { handle = handle }	-- for re-granting to a spawned child: {__right = p.handle}

	function p.reset(mode)
		sys.send(handle, { op = "reset", mode = mode or "shutdown" })
	end
	function p.stall(us)
		sys.send(handle, { op = "stall", us = us })
	end
	return p
end

return M
