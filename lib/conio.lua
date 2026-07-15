-- conio: the sole task anywhere with los.platform (raw console-write,
-- reset, stall). every other proc holds, at most, a send-right to
-- this task's mailbox -- never the raw primitives themselves. that
-- absence is the whole enforcement: there is no check to get wrong,
-- because the function simply is not reachable from anywhere else.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform")

while true do
	local m = thread.recv(sys.SELF)

	if m.op == "write" then
		platform.serwrite(m.data)
	elseif m.op == "reset" then
		platform.reset(m.mode)
	elseif m.op == "stall" then
		platform.stall(m.us)
	end
end
