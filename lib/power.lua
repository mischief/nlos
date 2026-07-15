-- power: the sole task anywhere with los.platform.power (reset,
-- stall). every other proc holds, at most, a send-right to this
-- task's mailbox and talks by message: {op="reset", mode=m} or
-- {op="stall", us=n}.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.power")

while true do
	local m = thread.recv(sys.SELF)

	if m.op == "reset" then
		platform.reset(m.mode)
	elseif m.op == "stall" then
		platform.stall(m.us)
	end
end
