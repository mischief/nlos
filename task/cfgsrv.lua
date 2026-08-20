-- cfgsrv: a FAT volume on the block device, served as /config.
--
-- blksrv holds the device, so the disk arrives as /dev/data and sectors
-- go over a port, as partsrv and gefssrv reach theirs. A blank device
-- is reamed rather than refused: an empty store is a machine that has
-- kept nothing yet, not a broken one.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local srv = require("srv")
local fat = require("fat")
local fatfs = require("fatfs")
local buf = require("los.buf")

-- how often what was written reaches the store. The volume is a handful
-- of small files and the cost of a sync is the host's, so this is about
-- not losing a write to a closed tab rather than about throughput.
local SYNCMS = 1000

local a = ...

thread.spawn(function()
	local init = require("svcarg")(a)
	local blk = init.blk.__right

	local N = ns.new()

	assert(N:mount("/dev", mnt.new(blk), "mnt",
	    { port = { __right = blk } }))

	local h = assert(N:open("/dev/data", "rw"))
	local st = assert(N:stat("/dev/data"), "cfgsrv: no /dev/data")
	local size = st.size or st.length

	-- the calls lib/fat wants, over one seekable handle. read answers a
	-- string and readbuf a buffer: fat/vol.lua unpacks the boot sector
	-- with string.sub, fat/blk.lua caches buffers.
	local function rd(_, off, len)
		h:seek("set", off)

		local s = h:read(len) or ""

		if #s < len then
			s = s .. string.rep("\0", len - #s)
		end
		return s
	end

	local dev = {
		read = rd,
		readbuf = function(self, off, len)
			local s = rd(self, off, len)
			local b = buf.new(#s)

			b:copy(1, s)
			return b
		end,
		write = function(_, off, s)
			h:seek("set", off)
			return h:write(buf.is(s) and s:str() or s)
		end,
		size = function() return size end,
		sync = function() end,		-- a write is already through
	}

	-- a blank device does not merely answer nil: lib/fat reads a boot
	-- sector of zeroes and raises on the arithmetic. Either way it is
	-- a volume that has to be made.
	local ok, fs = pcall(fat.open, dev, { freecount = true })

	if not ok or not fs then
		assert(fat.ream(dev, { secsz = 512, label = "CONFIG" }))
		fs = assert(fat.open(dev, { freecount = true }),
		    "cfgsrv: reamed and still no FAT volume")
		print("cfgsrv: made a new config volume")
	end

	local vol = fatfs.new(fs)

	srv.serve(vol, sys.SELF, {
		workers = 1,
		tick = { ms = SYNCMS, fn = function() vol.sync() end },
	})
end)
thread.run()
