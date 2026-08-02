-- p9srv: the virtio-9p transport, served as an ordinary dev backend.
-- see lib/espsrv.lua, which this mirrors exactly -- the disk capability
-- there is los.fs; here it's los.platform.p9 (PRIV_P9 in kernel.c).
-- everything else (one owning task, everyone else gets a mount/right)
-- is identical.

local p9fs = require("p9fs")
local srv = require("srv")

-- workers: every p9fs call is a round trip to the device, and the
-- transport can hold VIRTIO_9P_SLOTS of them at once. Served one at a
-- time, a client's concurrent reads queued behind each other and that
-- depth went unused -- so the window here is what makes a scatter of
-- reads overlap rather than merely interleave.
--
-- Matched to the transport's depth rather than tuned: past it the extra
-- workers only wait for a slot.
srv.main(function()
	return p9fs.new()
end, { workers = 8 })
