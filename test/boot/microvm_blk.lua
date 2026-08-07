-- virtio-blk through the real namespace, the way microvm_p9mount.lua
-- exercises virtio-9p. /task/blksrv.lua is spawned at boot as a
-- PRIV_BLK driver and grants a "blk" capability; mounting it is
-- ordinary mnt.lua/ns.lua work.
--
-- what is mounted is not a filesystem. /data is one file that IS the
-- disk, so every read below is a byte range of a raw device that
-- lib/blkfs.lua turned into sectors -- see its header on why the seam
-- is there.
--
-- the host side is seeded by tools/boottest-microvm.lua: 2048 sectors,
-- each beginning with its own index, so a read can prove it landed
-- where it asked to. That harness also re-checks the image after the
-- guest exits, which is the half of the write test that cannot be done
-- from in here.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(20)

local SECSZ = 512
local SECTORS = 2048

local function sector(i)
	local mark = string.format("sector %04d\n", i)

	return mark .. string.rep(".", SECSZ - #mark)
end

local caps = sys.granted()

if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
	tap.diag("no virtio-blk device found; the rest cannot run")
	tap.done()
	return
end

local N = ns.new()
local mok, merr = N:mount("/dev", mnt.new(caps.blk), "mnt",
    { port = { __right = caps.blk } })

if not tap.ok(mok, "mounted the block device at /dev") then
	tap.diag("mount failed: " .. tostring(merr))
	tap.done()
	return
end

-- ---- the tree ----

local names = {}

for _, e in ipairs(N:readdir("/dev") or {}) do
	names[#names + 1] = e.name
end
table.sort(names)
tap.ok(table.concat(names, ",") == "ctl,data",
    "readdir /dev -> " .. table.concat(names, ","))

local ctl = N:readfile("/dev/ctl")
local nsec = tonumber(ctl and ctl:match("sectors (%d+)"))

if not tap.ok(nsec == SECTORS, "ctl reports " .. tostring(nsec) ..
    " sectors") then
	tap.diag("ctl was: " .. tostring(ctl))
end

local st = N:stat("/dev/data")

tap.ok(st and st.size == SECTORS * SECSZ,
    "/dev/data is the whole device (" .. tostring(st and st.size) ..
    " bytes)")

-- ---- reads ----

-- aligned, one sector, at an offset far enough in that a driver
-- ignoring the lba would have to be lucky
local one = N:readfile("/dev/data")

tap.ok(#one == SECTORS * SECSZ, "reading the whole device returns it all")

-- a fresh open each time, so every read below comes off the device
-- rather than out of a handle this proc has been carrying
local function readat(off, n)
	local h <close> = assert(N:open("/dev/data", "r"))

	h:seek("set", off)
	return (h:read(n))
end

tap.ok(readat(17 * SECSZ, SECSZ) == sector(17),
    "an aligned single-sector read lands on the sector it named")

-- unaligned and spanning a boundary: the case blkfs.lua has to widen to
-- whole sectors and trim again, and the one that would silently return
-- shifted data if the trim were off by the head slice.
local UOFF = 3 * SECSZ + 503		-- 2039, and 2039 + 40 crosses 2048
local want = (sector(3) .. sector(4)):sub(504, 543)

tap.ok(readat(UOFF, 40) == want,
    "an unaligned read across a sector boundary returns the right bytes")

-- ONE read, larger than anything the layers underneath can move in a
-- single step: bigger than dev.IOUNIT, so lib/mnt.lua has to issue
-- several requests, and bigger than one virtio transfer, so blkfs has
-- to issue several of those. The caller sees neither number.
--
-- This is the whole point of putting the chunking in the mount driver
-- rather than in the backend or the caller, and it is what a plan 9
-- read syscall does across a mount with an 8K msize.
local BIG = 200 * SECSZ			-- 100K, against a 60K iounit
local big = readat(0, BIG)
local bigok = #big == BIG

for i = 0, 199 do
	if big:sub(i * SECSZ + 1, (i + 1) * SECSZ) ~= sector(i) then
		bigok = false
		break
	end
end
tap.ok(bigok, "a single read larger than a message comes back whole (" ..
    #big .. " of " .. BIG .. " bytes)")

-- eof is "", not an error, and not a short disk's worth of zeroes
tap.ok(readat(SECTORS * SECSZ, SECSZ) == "",
    "reading at the end of the device returns eof")

-- ---- several requests in flight ----
--
-- the whole reason virtio_blk.c has a slot table and a reap that drains
-- the entire used ring, and none of it is exercised by a serial reader:
-- with one request outstanding, a driver that filed completions under
-- the wrong slot, or that dropped the ones that were not its own, would
-- behave identically. Sectors carry their own indices, so a reply
-- delivered against the wrong request fails on content rather than on
-- a count.
--
-- Compared against the serial read of the same device above.

local function collect(f, window, blocksize)
	local parts = {}

	for block, err in f:readparallel(window, blocksize) do
		if not block then
			return nil, err
		end
		parts[#parts + 1] = block
	end
	return table.concat(parts)
end

do
	local f <close> = assert(N:open("/dev/data", "r"))
	local got, gerr = collect(f, 8, 4096)

	if not tap.ok(got == one,
	    "readparallel(8) over the whole device matches the serial read") then
		tap.diag("got " .. tostring(got and #got or gerr) ..
		    ", wanted " .. #one)
	end
end

-- a window wider than VIRTIO_BLK_SLOTS, so the driver runs out of slots
-- and blk.read takes the branch that yields and retries rather than
-- failing. Nothing above has reached that path.
do
	local f <close> = assert(N:open("/dev/data", "r"))
	local got, gerr = collect(f, 24, 4096)

	if not tap.ok(got == one,
	    "a window wider than the slot table still reads correctly") then
		tap.diag("got " .. tostring(got and #got or gerr) ..
		    ", wanted " .. #one)
	end
end

-- ---- the write ----
--
-- unaligned and across a boundary on purpose: this is the read-modify-
-- write path. The harness checks the same bytes in the host image
-- afterwards, including the neighbours -- a version that placed the
-- marker correctly and destroyed everything around it would pass the
-- readback here and fail there.

local MARK = "MARKER-FROM-LUAOS"
local MARKOFF = 1015

do
	local h <close> = assert(N:open("/dev/data", "rw"))

	h:seek("set", MARKOFF)

	local n = h:write(MARK)

	tap.ok(n == #MARK, "wrote " .. tostring(n) .. " bytes across a sector boundary")
end

-- and the same for a write: one call carrying more than a message can
-- hold, which dev.writeloop has to split and the far side reassemble.
-- Written high up the device so it disturbs nothing checked elsewhere.
local BIGOFF = 1000 * SECSZ
local BIGDATA = string.rep("write-across-messages;", 4000):sub(1, 88000)

do
	local h <close> = assert(N:open("/dev/data", "rw"))

	h:seek("set", BIGOFF)
	tap.ok(h:write(BIGDATA) == #BIGDATA,
	    "a single write larger than a message is accepted whole (" ..
	    #BIGDATA .. " bytes)")
end

tap.ok(readat(BIGOFF, #BIGDATA) == BIGDATA,
    "and it reads back byte for byte")

local back = readat(MARKOFF - 8, #MARK + 16)
local expect = (sector(1) .. sector(2)):sub(MARKOFF - SECSZ - 8 + 1,
    MARKOFF - SECSZ)
    .. MARK ..
    (sector(1) .. sector(2)):sub(MARKOFF - SECSZ + #MARK + 1,
    MARKOFF - SECSZ + #MARK + 8)

if not tap.ok(back == expect,
    "the write reads back with its neighbours intact") then
	tap.diag("got:  " .. string.format("%q", back))
	tap.diag("want: " .. string.format("%q", expect))
end

-- ---- a sector arrives without being copied ----
--
-- The driver reads into a buffer and the reply gives it away, so a
-- client asking for whole sectors is handed the driver's own bytes.
-- What proves it is a buffer arriving where a string would have been.
local D = mnt.new(caps.blk)
local dh = D.open(D.walk(D.attach(), "data"), "r")

tap.ok(D.readbuf ~= nil, "a mount can ask for the bytes as they came")

local raw = D.readbuf(dh, 17 * SECSZ, SECSZ)

tap.is(type(raw), "userdata", "an aligned read comes back as a buffer")
tap.is(raw:str(), sector(17), "holding the sector it named")
tap.is(D.read(dh, 17 * SECSZ, SECSZ), sector(17),
    "and read still answers with a string")

tap.done()
