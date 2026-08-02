local tap = require("tap")
local thread = require("los.thread")
tap.plan(1)
local ticks = 0
thread.spawn(function() local i=0 while true do i=i+1 end end)
thread.spawn(function()
	for _ = 1, 20 do ticks = ticks + 1; coroutine.yield() end
	tap.ok(true, "a yielding sibling ran 20 times beside a spinner")
	tap.done()
end)
thread.run()
