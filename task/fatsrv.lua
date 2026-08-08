-- fatsrv: the flash, as FAT volumes served on a port.
--
-- Holds PRIV_FLASH and lays the filesystem on the device itself, so a
-- sector is a call and not a message. Both partitions here: luafs is
-- the root, config is mounted inside it.
--
-- One worker, since lib/fat has no locks. Clients queue at the port.
-- srv.serve's tick syncs every volume between requests.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local srv = require("srv")
local fat = require("fat")
local fatfs = require("fatfs")
local blkfs = require("blkfs")
local flash = require("los.platform.flash")
local buf = require("los.buf")

-- one volume as the calls lib/fat wants. blkfs does the sector
-- arithmetic; going straight to its backend is what drops the port.
--
-- read returns a string and readbuf the buffer: fat/vol.lua unpacks the
-- boot sector with string.sub, fat/blk.lua caches buffers. Coming over
-- a port these were the same thing, since the message carried bytes.
local function device(vol)
	local raw = flash.volume(vol)
	local nsec, secsz = raw.capacity()
	local B = blkfs.new(raw)
	local h = B.open(B.walk(B.attach(), "data"), "rw")

	local function rd(_, off, len)
		return B.read(h, off, len)
	end

	return {
		readbuf = rd,
		read = function(self, off, len)
			local d = rd(self, off, len)

			return buf.is(d) and d:str() or d
		end,
		write = function(_, off, s) return B.write(h, off, s) end,
		size = function() return nsec * secsz end,
		sync = function() end,		-- a write is already through
	}
end

thread.spawn(function()
	local syncms = 5000
	local nvol = flash.count and flash.count() or 1

	-- ream writes a fresh volume where there is nothing to open. Never
	-- for the root: on a bad read that throws the programs away.
	local function volume(vol, ream, cache)
		local dev = device(vol)
		local fs = fat.open(dev, { cache = cache })

		if not fs and ream then
			assert(fat.ream(dev, { secsz = 4096, label = "CONFIG",
			    cache = cache }))
			fs = fat.open(dev, { cache = cache })
		end
		return assert(fs, "volume " .. vol .. ": no FAT volume here")
	end

	-- names are ours to choose now; partitions.csv fixes what is there.
	local WHERE = { [2] = "/config" }
	local vols = { fatfs.new(volume(1, false)) }
	local B = vols[1]

	if nvol > 1 then
		local V = ns.new()
		local n = 0

		assert(V:mount("/", B, "fatfs"))
		for i = 2, nvol do
			local at = WHERE[i] or ("/vol" .. i)
			-- a missing volume is an older layout, not a
			-- failure. Small cache: a few files, read once.
			local ok, fs = pcall(volume, i, true, 8)

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
