-- power: the sole task anywhere with los.platform.power (reset,
-- stall). every other proc holds, at most, a send-right to this
-- task's mailbox and talks by message: {op="reset", mode=m} or
-- {op="stall", us=n}.
--
-- No los.thread on purpose: this loop has no concurrency in it, and on
-- a proc with no threads thread.recv is exactly the tryrecv/block below
-- -- for which it costs 24KB resident, more than half this task. A task
-- that needs alt, a channel or a timeout should still take the
-- scheduler.

local sys = require("los.sys")
local platform = require("los.platform.power")

while true do
	local ok, m = sys.tryrecv(sys.SELF)

	if not ok then
		sys.block(sys.SELF)	-- sleep until there is one
	elseif m.op == "reset" then
		platform.reset(m.mode)
	elseif m.op == "stall" then
		platform.stall(m.us)
	end
end
