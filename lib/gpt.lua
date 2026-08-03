-- Reading a GUID partition table off a device.
--
-- Enough of the GPT to find a partition and hand back where it is: the
-- header at LBA 1, then the entry array it points at. Not a writer -- the
-- host makes the table (tools/mkimage.lua, via sfdisk), and all the guest
-- needs is to locate the gefs partition on a disk whose front holds an
-- ESP the firmware booted from.
--
-- The device is the lib/dev / gefs device shape's common ground: a table
-- answering read(off, len) in bytes and size(). blkfs's /data is one, and
-- so is gefs.io over a file, so the same parser runs on the real disk and
-- on a disk image under test.
--
-- Little-endian throughout, which is the GPT spec and also x86; string
-- offsets are 1-based, so a field at spec offset N is byte N+1 here.

local M = {}

local SIG = "EFI PART"
local HEADER_LBA = 1

-- a type GUID is stored mixed-endian (the first three fields little, the
-- last two big), the same layout /proc/partitions and every tool prints.
-- We compare and print the canonical string form, so the encoding only
-- has to be undone once, here.
local function guidstr(b)
	local d1 = string.unpack("<I4", b, 1)
	local d2 = string.unpack("<I2", b, 5)
	local d3 = string.unpack("<I2", b, 7)
	local d4 = string.unpack(">I2", b, 9)
	local d5a, d5b = string.unpack(">I2>I4", b, 11)
	return string.format("%08x-%04x-%04x-%04x-%04x%08x",
	    d1, d2, d3, d4, d5a, d5b)
end

-- the UTF-16LE partition name, ASCII range only (which is all sfdisk
-- writes and all we name partitions), trimmed at the first NUL.
local function name16(b)
	local out = {}
	for i = 1, #b, 2 do
		local c = string.unpack("<I2", b, i)
		if c == 0 then break end
		out[#out + 1] = (c < 128) and string.char(c) or "?"
	end
	return table.concat(out)
end

-- read whole sectors, so a caller working in LBAs never converts to bytes
local function readsec(dev, secsz, lba, n)
	return dev:read(lba * secsz, n * secsz)
end

-- parse(dev[, secsz]) -> { partitions = { {name, type, first, last,
-- sectors, off, bytes}, ... } } or nil, err. off/bytes are byte figures
-- ready for gefs.slice; first/last/sectors are LBAs.
function M.parse(dev, secsz)
	secsz = secsz or 512

	local hdr = readsec(dev, secsz, HEADER_LBA, 1)
	if hdr:sub(1, 8) ~= SIG then
		return nil, "no GPT signature at LBA 1"
	end

	-- header fields (spec offsets): 72 entries LBA (i8), 80 count (i4),
	-- 84 entry size (i4)
	local entlba = string.unpack("<I8", hdr, 73)
	local nent = string.unpack("<I4", hdr, 81)
	local entsz = string.unpack("<I4", hdr, 85)

	if nent == 0 or entsz < 128 then
		return nil, "GPT header describes no usable entries"
	end

	-- the entry array, however many sectors it spans
	local nbytes = nent * entsz
	local nsec = (nbytes + secsz - 1) // secsz
	local arr = readsec(dev, secsz, entlba, nsec)

	local parts = {}
	for i = 0, nent - 1 do
		local e = arr:sub(i * entsz + 1, (i + 1) * entsz)
		local typ = guidstr(e:sub(1, 16))
		-- an all-zero type GUID is an unused slot
		if typ ~= "00000000-0000-0000-0000-000000000000" then
			local first = string.unpack("<I8", e, 33)
			local last = string.unpack("<I8", e, 41)
			parts[#parts + 1] = {
				name = name16(e:sub(57, 128)),
				type = typ,
				first = first,
				last = last,
				sectors = last - first + 1,
				off = first * secsz,
				bytes = (last - first + 1) * secsz,
			}
		end
	end
	return { partitions = parts }
end

-- find the first partition whose name matches, or nil. Name because that
-- is what a person sets and reads; type GUID is available on each entry
-- for a caller that would rather match on it.
function M.find(dev, name, secsz)
	local gpt, err = M.parse(dev, secsz)
	if gpt == nil then
		return nil, err
	end
	for _, p in ipairs(gpt.partitions) do
		if p.name == name then
			return p
		end
	end
	return nil, "no partition named " .. name
end

return M
