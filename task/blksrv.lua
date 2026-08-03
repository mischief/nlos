-- blksrv: the block device, served as an ordinary dev backend.
-- see task/p9srv.lua and lib/espsrv.lua, which this mirrors -- the
-- disk capability there is los.fs and los.platform.p9; here it is
-- los.platform.blk (PRIV_BLK in kernel.c). one owning task, everyone
-- else gets a mount.
--
-- what it serves is one file rather than a filesystem: see lib/blkfs.lua.

local blkfs = require("blkfs")
local srv = require("srv")

-- workers matched to VIRTIO_BLK_SLOTS, for the reason p9srv gives at
-- length: every call is a round trip to the device and the transport
-- holds that many at once, so served one at a time a client's
-- concurrent reads queue behind each other and the depth goes unused.
srv.main(function()
	return blkfs.new()
end, { workers = 8 })
