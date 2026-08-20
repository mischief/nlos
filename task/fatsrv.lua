-- fatsrv: this machine's FAT volumes, served on a port.
--
-- Holds the devices and lays the filesystem on them directly, so a
-- sector is a call and not a message: PRIV_FLASH for the flash, whose
-- luafs is the root, and PRIV_BLK for the card. One server rather than
-- one per device, since a second would be a second copy of lib/fat.

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

-- `at` and `bytes` name a slice: a partition, where the whole device is
-- not one volume. Everything above works in offsets from zero.
local function device(raw, at, bytes)
	local nsec, secsz = raw.capacity()
	local B = blkfs.new(raw)
	local h = B.open(B.walk(B.attach(), "data"), "rw")

	at = at or 0
	bytes = bytes or (nsec * secsz)

	local function rd(_, off, len)
		return B.read(h, at + off, len)
	end

	return {
		readbuf = rd,
		read = function(self, off, len)
			local d = rd(self, off, len)

			return buf.is(d) and d:str() or d
		end,
		write = function(_, off, s) return B.write(h, at + off, s) end,
		size = function() return bytes end,
		sync = function() end,		-- a write is already through
	}
end

-- the removable one, whose module says for itself whether a card
-- answered. Where its FAT lives is cardfat below.
local function card()
	local ok, blk = pcall(require, "los.platform.blk")

	if not ok or type(blk) ~= "table" or not blk.capacity then
		return nil
	end
	return blk.capacity() and blk or nil
end

-- where the card's FAT is: inside a partition, or at the front where
-- the card is one volume. The table is asked about first, because a GPT
-- disk carries a protective MBR close enough to a boot sector that
-- fat.open gets some way into it before failing.

-- The first partition that opens wins. Naming one would be better for a
-- machine's own disk, as partsrv does, but these labels are not ours.
-- freecount = false, and it is not a detail. countfree walks the whole
-- FAT, which on a 30GB card is millions of entries at the card's clock:
-- minutes of boot for a number nothing needs yet. Every use of it in
-- lib/fat is guarded, and fsinfo has a sentinel for "unknown", so a
-- volume opened this way still allocates and still writes.
local function fatopen(dev, cache)
	return fat.open(dev, { cache = cache, freecount = false })
end

local function cardfat(raw, cache)
	local whole = device(raw)
	local ok, tbl = pcall(require("gpt").parse, whole)

	if ok and tbl then
		for i, p in ipairs(tbl.partitions) do
			local dev = device(raw, p.off, p.bytes)

			if fatopen(dev, cache) then
				return dev, "partition " .. i ..
				    (p.name ~= "" and
				     (" (" .. p.name .. ")") or "")
			end
		end
		return nil
	end
	if fatopen(whole, cache) then
		return whole, "whole disk"
	end
	return nil
end

thread.spawn(function()
	local syncms = 5000
	local nvol = flash.count and flash.count() or 1

	-- ream writes a fresh volume where there is nothing to open. Never
	-- for the root: on a bad read that throws the programs away.
	--
	-- `dev` where the caller already resolved one (the card, whose FAT
	-- may be inside a partition), `raw` where it is a whole volume.
	local function volume(v, at, ream, cache)
		local dev = v.dev or device(v.raw)
		local opts = { cache = cache, freecount = not v.nofree }
		local fs = fat.open(dev, opts)

		if not fs and ream then
			assert(fat.ream(dev, { secsz = v.secsz or 4096,
			    label = v.label or "CONFIG", cache = cache }))
			fs = fat.open(dev, opts)
		end
		return assert(fs, at .. ": no FAT volume here")
	end

	-- touch this and reboot to make a filesystem on the card. Read
	-- through the volumes below, so it lives on the writable flash and
	-- survives exactly one boot.
	local REAMFLAG = "/config/ream-sd"

	-- names are ours to choose now; partitions.csv fixes what is there.
	local WHERE = { [2] = "/config" }
	local vols = { fatfs.new(volume({ raw = flash.volume(1) }, "/", false)) }
	local B = vols[1]
	-- what goes above the root, in order. The card is last and is not
	-- reamed: an unreadable partition on removable media is a card
	-- belonging to someone else, not a volume waiting to be made.
	local more = {}

	for i = 2, nvol do
		more[#more + 1] = { at = WHERE[i] or ("/vol" .. i),
		    raw = flash.volume(i), ream = true, cache = 8 }
	end

	-- Protected end to end: the flash is this machine's root, and a
	-- card someone put in must not take it away. The worst it may do
	-- is leave the board without /sd.

	local ok, sd = pcall(card)
	local dev, where

	if ok and sd then
		ok, dev, where = pcall(cardfat, sd)
		if not ok then
			print("fatsrv: /sd: " .. tostring(dev))
			dev = nil
		end
	end
	-- a card with nothing readable on it is still a card: kept as a
	-- candidate so an asked-for ream has a device to write, where
	-- before it was dropped here and there was nothing to ream.
	if not dev and ok and sd then
		dev, where = device(sd), "no volume"
	end

	if dev then
		print("fatsrv: /sd: " .. where)
		-- the default cache, not /config s handful: the FAT and the
		-- directories of a 30GB volume are revisited constantly, and
		-- eight sectors of it thrash.
		-- 512 on a card, which is what its sectors are; the flash
		-- volumes use the erase block.
		more[#more + 1] = { at = "/sd", dev = dev, ream = false,
		    card = true, secsz = 512, label = "LUAOS", nofree = true }
	end

	if #more > 0 then
		local V = ns.new()
		local n = 0

		assert(V:mount("/", B, "fatfs"))
		for _, v in ipairs(more) do
			local at = v.at
			-- a missing volume is an older layout, not a
			-- failure. Small cache: a few files, read once.
			local ream = v.ream

			-- the card is reamed only where somebody asked for
			-- it by name. The flag is a file rather than a
			-- setting because it is spent: making a filesystem
			-- over somebody's photographs must not be something
			-- a machine does twice.
			if v.card and V:stat(REAMFLAG) then
				ream = true
				V:remove(REAMFLAG)
				print("fatsrv: /sd: reaming, as " ..
				    REAMFLAG .. " asked")
			end

			local ok, fs = pcall(volume, v, at, ream, v.cache)

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
