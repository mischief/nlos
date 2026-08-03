-- gefs in a GPT partition, found by reading the table.
--
-- The disk is a real GUID partition table: an ESP up front (the layout a
-- firmware-booted disk has) and a gefs partition after it, seeded by the
-- host (tools/boottest-microvm.lua --gefsgpt). The whole disk is one
-- seekable file over virtio-blk, so the guest reads the GPT off it, finds
-- the gefs partition by name, and mounts a volume that occupies only that
-- window -- gefs.slice shifting every access into the partition, gefs
-- itself knowing nothing about partitions and the parser nothing about
-- gefs.
--
-- This is the microvm half of one disk layout for both platforms: here
-- the ESP is ignored and the ELF booted directly; under firmware the ESP
-- holds the loader and the same gefs partition sits beside it.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local gefs = require("gefs")
local gpt = require("gpt")
local tap = require("tap")

tap.plan(8)

local SMALL = "hello from gefs\n"
local BIG = ("gefs"):rep(10000)

local caps = sys.granted()

if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
	tap.diag("no virtio-blk device; the rest cannot run")
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
local h = assert(N:open("/dev/data", "rw"))
local disk = gefs.io.wrap(h, size)

-- the table, off the raw disk
local g, gerr = gpt.parse(disk)

if not tap.ok(g ~= nil, "read a GPT off the disk") then
	tap.diag("gpt.parse failed: " .. tostring(gerr))
	tap.done()
	return
end

-- both partitions are there, named
local byname = {}
for _, p in ipairs(g.partitions) do byname[p.name] = p end
tap.ok(byname.EFI ~= nil, "the ESP partition is present")

local part = byname.gefs

if not tap.ok(part ~= nil, "found the gefs partition by name") then
	tap.done()
	return
end
tap.diag(("gefs partition: %d bytes at offset %d"):format(part.bytes, part.off))

-- mount gefs on just that window
local vol = gefs.slice(disk, part.off, part.bytes)
local ok, fs = pcall(gefs.open, vol)

if not tap.ok(ok, "opened the gefs volume in the partition") then
	tap.diag("open failed: " .. tostring(fs))
	tap.done()
	return
end

local m = fs:mount("main")
tap.ok(m:readfile("/hello") == SMALL, "read the small file from the partition")
tap.ok(m:readfile("/dir/big") == BIG,
    "read the large file from the partition (spans blocks)")

tap.done()
