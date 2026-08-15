-- svcarg: how a task takes its start.
--
--	local m0, cfg = require("svcarg")(...)
--
-- lib/svc.lua puts the start in the spawn arg; a payload starting a task
-- by hand sends it as a first message.

-- Rights are top level in both forms, so read those from `m0`. Scalars
-- sit under `args` in a service list and beside the rights in a message,
-- so read those from `cfg`.

-- Call at file scope. `...` is the chunk's, and a task that waits until
-- it is inside thread.spawn has already lost it.
local sys = require("los.sys")
local thread = require("los.thread")

return function(a)
	local m0 = type(a) == "table" and a or thread.recv(sys.SELF)

	return m0, m0.args or m0
end
