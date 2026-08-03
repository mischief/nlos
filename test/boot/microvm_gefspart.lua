-- gefs on a partition, the composed way: a partition server under a
-- filesystem server, which is what init does to put gefs in the
-- namespace.
--
-- blksrv serves the whole disk. partsrv mounts it, reads the GPT, and
-- serves the gefs partition as its own /data. gefssrv mounts THAT -- not
-- the raw disk -- and serves the filesystem, knowing nothing about the
-- table. Three servers, each doing one thing, composed by mounts. The
-- disk is the --gefsgpt layout: an ESP and a gefs partition holding the
-- host-seeded files.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(5)

local SMALL = "hello from gefs\n"
local BIG = ("gefs"):rep(10000)

local caps = sys.granted()

if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
	tap.diag("no virtio-blk device; the rest cannot run")
	tap.done()
	return
end

-- the partition server: the gefs partition presented as /data
local _, ph = sys.spawn(io.open("/task/partsrv.lua"):read("a"),
    { name = "part" })
sys.send(ph, { blk = { __right = caps.blk }, partition = "gefs" })

-- the filesystem server, mounting the partition rather than the raw disk
local _, gh = sys.spawn(io.open("/task/gefssrv.lua"):read("a"),
    { name = "gefs" })
sys.send(gh, { blk = { __right = ph }, label = "main", syncms = 500 })

local N = ns.new()

if not tap.ok(N:mount("/n/gefs", mnt.new(gh), "mnt",
    { port = { __right = gh } }), "mounted the served volume at /n/gefs") then
	tap.done()
	return
end

tap.ok(N:readfile("/n/gefs/hello") == SMALL,
    "read /n/gefs/hello down through partsrv and gefssrv")
tap.ok(N:readfile("/n/gefs/dir/big") == BIG,
    "read the large file the same way")

-- the listing a session would ask for: readdir over the mount. This is
-- the command the interactive shell runs -- ns.current():readdir("/n/gefs")
local names = {}
for _, e in ipairs(N:readdir("/n/gefs") or {}) do
	names[e.name] = true
end
tap.ok(names.hello and names.dir,
    "readdir /n/gefs lists the partition's files")

tap.done()
