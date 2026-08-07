-- blksrv: the block device, served as an ordinary dev backend.
-- see task/p9srv.lua and lib/espsrv.lua, which this mirrors -- the
-- disk capability there is los.fs and los.platform.p9; here it is
-- los.platform.blk (PRIV_BLK in kernel.c). one owning task, everyone
-- else gets a mount.
--
-- what it serves is one file rather than a filesystem: see lib/blkfs.lua.
--
-- A capability may bring more than one device: the flash has a
-- partition for programs and a partition for what the machine knows
-- about itself. All of them are served here, by this one proc, because
-- a proc is the expensive thing on a board with 512KB of ram and a
-- second device is a mount point. The first is at the root, so a client
-- reading /data sees the device it always did; the rest are numbered,
-- /2/data and so on.

local blkfs = require("blkfs")
local srv = require("srv")

-- the flash names its volumes; the card is one device and says nothing.
local flash = select(2, pcall(require, "los.platform.flash"))
local nvol = 1

if type(flash) == "table" and flash.count then
	nvol = flash.count()
end

local function backend()
	if nvol <= 1 then
		return blkfs.new()
	end

	-- one namespace, served as one tree: lib/nsfs.lua makes a
	-- namespace look like a single backend, walks crossing the mount
	-- points as NS resolves them. The cost is per walk, not per read,
	-- so it does not reach the sectors.
	local N = require("ns").new()

	assert(N:mount("/", blkfs.new(flash.volume(1)), "blkfs"))
	for i = 2, nvol do
		assert(N:mount("/" .. i, blkfs.new(flash.volume(i)), "blkfs"))
	end
	return require("nsfs").new(N)
end

-- workers matched to VIRTIO_BLK_SLOTS, for the reason p9srv gives at
-- length: every call is a round trip to the device and the transport
-- holds that many at once, so served one at a time a client's
-- concurrent reads queue behind each other and the depth goes unused.
srv.main(backend, { workers = 8 })
