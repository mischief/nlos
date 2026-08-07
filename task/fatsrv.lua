-- fatsrv: FAT volumes served as an ordinary dev backend.
--
-- Stacks on a block device the way task/gefssrv.lua does: the block
-- server holds the device capability, this holds an ordinary right to
-- it, handed over at spawn.
--
--	local _, f = sys.spawn(src, { name = "fatsrv" })
--	sys.send(f, { blk = { __right = flashright } })
--	N:mount("/", mnt.new(f), "mnt", { port = { __right = f } })
--
-- so f is both how the device reaches this proc and, once serving, the
-- mount right every client holds.
--
-- The device underneath may be the flash partition or the microSD card.
-- Neither is named here: what arrives is a right, and the sectors it
-- reaches are whatever the proc that granted it decided.
--
-- A block server offering more than one device -- the flash, whose
-- second partition holds what the machine knows about itself -- is
-- served as one tree by this one proc: the first volume is the root and
-- the rest are mounted under it at the names `mounts` gives. That is
-- what keeps a second partition from costing a second server; a proc is
-- the expensive thing here, not a mount point.
--
--	sys.send(f, { blk = ..., mounts = { "/config" } })
--
-- One worker, as gefssrv has. lib/fat has no locks, so a request runs
-- to completion -- across its device round trips -- before the next
-- starts. Many clients may send at once; they queue at the port.
--
-- Writes reach the flash at a sync, so the volume is committed on a
-- clock: srv.serve's tick calls sync on every volume between requests
-- and once more at shutdown, and a client can force one by writing
-- "sync" to its /ctl.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local srv = require("srv")
local fat = require("fat")
local fatfs = require("fatfs")
local gefsio = require("gefs.io")

thread.spawn(function()
	local init = thread.recv(sys.SELF)
	local blk = init.blk.__right
	local syncms = init.syncms or 5000
	local mounts = init.mounts or {}

	-- mount the block device and open /data as a seekable file,
	-- exactly as any other client of blksrv would. The filesystem sits
	-- on the file and knows nothing about flash or about SPI.
	local N = ns.new()

	assert(N:mount("/dev", mnt.new(blk), "mnt",
	    { port = { __right = blk } }))

	-- one volume of that device: the bytes at `path`, as a filesystem.
	-- `ream` writes a fresh volume where there is nothing to open,
	-- which is how a partition the build never wrote comes up empty
	-- rather than absent. Only ever true for a volume that is not the
	-- root: reaming that on a bad read would throw the programs away.
	local function volume(path, ream, cache)
		local ctl = N:readfile(path .. "/ctl")
		local size = tonumber(ctl and ctl:match("bytes (%d+)"))

		assert(size and size > 0,
		    path .. ": the block device did not report its size")

		local h = assert(N:open(path .. "/data", "rw"))
		-- a seekable handle as a device: read(off,len),
		-- write(off,s), size(), sync(). lib/fat and lib/gefs ask
		-- for the same four, so the wrapper serves both.
		local dev = gefsio.wrap(h, size)
		local fs = fat.open(dev, { cache = cache })

		if not fs and ream then
			assert(fat.ream(dev, { secsz = 4096, label = "CONFIG",
			    cache = cache }))
			fs = fat.open(dev, { cache = cache })
		end
		return assert(fs, path .. ": no FAT volume here")
	end

	-- the root volume is the device's first, at /dev/data. Every other
	-- is numbered by blksrv, /dev/2 upwards, and takes the name the
	-- spawner asked for.
	local vols = { fatfs.new(volume("/dev", false)) }
	local B = vols[1]

	if #mounts > 0 then
		local V = ns.new()
		local n = 0

		assert(V:mount("/", B, "fatfs"))
		for i, at in ipairs(mounts) do
			-- a device with fewer volumes than the spawner
			-- asked for is an older partition table, not a
			-- failure: serve what is there and say which is
			-- missing.
			-- a cache of its own, and a small one: this
			-- volume holds a few small files that are read
			-- once at boot, so sectors held here would be
			-- ram spent on nothing.
			local ok, fs = pcall(volume, "/dev/" .. (i + 1),
			    true, 8)

			if ok then
				local sub = fatfs.new(fs)

				assert(V:mount(at, sub, "fatfs"))
				vols[#vols + 1] = sub
				n = n + 1
			else
				print("fatsrv: " .. at .. ": " .. tostring(fs))
			end
		end
		if n > 0 then
			B = require("nsfs").new(V)
		end
	end

	srv.serve(B, sys.SELF, {
		workers = 1,
		tick = { ms = syncms, fn = function()
			for _, v in ipairs(vols) do
				v.sync()
			end
		end },
	})
end)
thread.run()
