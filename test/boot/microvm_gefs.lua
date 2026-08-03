-- gefs over the real block device: the seam lib/blkfs.lua was built for,
-- with an actual filesystem on the far side of it. The host seeds the
-- disk with a gefs volume (tools/boottest-microvm.lua --gefs, using
-- tools/gefs.lua), so this mounts a filesystem it did not make and reads
-- files it did not write -- the thing a self-contained ram test cannot
-- establish.
--
-- The block device is mounted the ordinary way (mnt.lua/ns.lua over the
-- blk capability, exactly as microvm_blk.lua does it). /data is then an
-- ordinary seekable file, which is all gefs.io wants, so gefs sits on it
-- with no knowledge of virtio anywhere in the stack.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local gefs = require("gefs")
local tap = require("tap")

tap.plan(9)

-- what the host seeded (tools/boottest-microvm.lua keeps the other copy)
local SMALL = "hello from gefs\n"
local BIG = ("gefs"):rep(10000)		-- 40000 bytes, several blocks
local GUEST = "written in the guest\n"

local caps = sys.granted()

if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
	tap.diag("no virtio-blk device; the rest cannot run")
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

-- the whole device is the volume; its length is what ream was told
local ctl = N:readfile("/dev/ctl")
local size = tonumber(ctl and ctl:match("bytes (%d+)"))

if not tap.ok(size and size > 0, "the device reports its size (" ..
    tostring(size) .. " bytes)") then
	tap.done()
	return
end

-- /data as a gefs device: one seekable handle, nothing more
local h = assert(N:open("/dev/data", "rw"))
local dev = gefs.io.wrap(h, size)

-- the freestanding kernel has no os.time; gefs takes a clock instead, and
-- uptime is the monotonic one this machine has. Nanoseconds, since that
-- is what the on-disk mtime field holds.
local function clock()
	return sys.uptime_ms() * 1000000
end

local ok, fs = pcall(gefs.open, dev, { clockfn = clock })

if not tap.ok(ok, "opened the gefs volume the host reamed") then
	tap.diag("open failed: " .. tostring(fs))
	tap.done()
	return
end

local m = fs:mount("main")

tap.ok(m:readfile("/hello") == SMALL,
    "read the small file the host wrote")
tap.ok(m:readfile("/dir/big") == BIG,
    "read the large file the host wrote (spans blocks)")
tap.ok(#fs:check() == 0, "the reamed volume checks out")

-- write from the guest and commit it. The readback here proves the round
-- trip through the tree; that the bytes reached the host image is the
-- harness's post-run check, the half an in-guest read cannot see.
m:createfile("/guest")
m:writefile("/guest", GUEST)
local sok, serr = pcall(function() fs:sync() end)
if not tap.ok(sok, "committed a write to the device") then
	tap.diag("sync failed: " .. tostring(serr))
end
tap.ok(m:readfile("/guest") == GUEST, "read the guest's own write back")

tap.done()
