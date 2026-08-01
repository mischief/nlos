-- p9srv: the virtio-9p transport, served as an ordinary dev backend.
-- see lib/espsrv.lua, which this mirrors exactly -- the disk capability
-- there is los.fs; here it's los.platform.p9 (PRIV_P9 in kernel.c).
-- everything else (one owning task, everyone else gets a mount/right)
-- is identical.

local p9fs = require("p9fs")
local srv = require("srv")

srv.main(function()
	return p9fs.new()
end)
