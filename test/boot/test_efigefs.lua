-- gefs on efi, from the disk the firmware booted.
--
-- The disk mkimage built is one GPT: the ESP the firmware loaded the
-- kernel from, and a gefs partition beside it (tools/mkgefs.lua put a
-- /README there). src/platform/efi/blk.c wraps EFI_BLOCK_IO into the same
-- los.platform.blk surface microvm gets from virtio, so the kernel spawns
-- blksrv and grants a blk cap here too -- and everything above is the
-- identical stack microvm_gefsgpt.lua drives: blkfs serves the whole disk
-- as /data, gpt reads the table, slice cuts out the partition, gefs
-- mounts it. One disk layout, the efi half.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local gefs = require("gefs")
local gpt = require("gpt")
local tap = require("tap")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
	tap.diag("no EFI_BLOCK_IO disk found; the rest cannot run")
	tap.done()
	return
end

local N = ns.new()

if not tap.ok(N:mount("/dev", mnt.new(caps.blk), "mnt",
    { port = { __right = caps.blk } }), "mounted the block device") then
	tap.done()
	return
end

local size = tonumber((N:readfile("/dev/ctl") or ""):match("bytes (%d+)"))

if not tap.ok(size and size > 0, "the disk reports its size (" ..
    tostring(size) .. " bytes)") then
	tap.done()
	return
end

local h = assert(N:open("/dev/data", "rw"))
local disk = gefs.io.wrap(h, size)

local g, gerr = gpt.parse(disk)

if not tap.ok(g ~= nil, "read the GPT off the firmware's disk") then
	tap.diag("gpt.parse failed: " .. tostring(gerr))
	tap.done()
	return
end

local part
for _, p in ipairs(g.partitions) do
	if p.name == "gefs" then part = p end
end

if not tap.ok(part ~= nil, "found the gefs partition beside the ESP") then
	tap.done()
	return
end
tap.diag(("gefs partition: %d bytes at offset %d"):format(part.bytes, part.off))

local vol = gefs.slice(disk, part.off, part.bytes)
local ok, fs = pcall(gefs.open, vol, { rdonly = true })

if not tap.ok(ok, "opened the gefs volume in the partition") then
	tap.diag("open failed: " .. tostring(fs))
	tap.done()
	return
end

tap.ok(fs:mount("main"):readfile("/README") == "hello from a gefs partition\n",
    "read /README, the file the build put in the partition")

tap.done()
