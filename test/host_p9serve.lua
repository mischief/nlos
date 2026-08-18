#!/usr/bin/env lua5.4
-- lib/p9serve.lua on the host: the 9P server over a dev backend, driven
-- with crafted 9P messages against a gefs volume. This is the bridge
-- lib/ninep.lua's codec and a dev backend meet at, and it is pure Lua --
-- no wire, no kernel -- so the host's own lua exercises it the way
-- host_gefs.lua exercises the filesystem.
--
-- The live thing -- a real 9p client over TCP to task/9pexport.lua -- is a
-- boot test's job; this pins the mapping (Twalk->walk, a directory read
-- as stat records, a raised dev error as Rerror) that a wire cannot see
-- into.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path
-- dev.lua wants los.sys for MAXMSG only; no kernel here to give it one
package.loaded["los.sys"] = { MAXMSG = 8192 }

local p9 = require("ninep")
local p9serve = require("p9serve")
local gefs = require("gefs")
local gefsfs = require("gefsfs")

local count, failed = 0, 0
local function ok(cond, name)
	count = count + 1
	io.write((cond and "ok " or "not ok ") .. count .. " - " .. name .. "\n")
	if not cond then failed = failed + 1 end
	return cond
end

-- a gefs volume with a file and a subdirectory
local dev = gefs.ram.new(64 * 1024 * 1024, 16384)
gefs.ream(dev, { user = "glenda" })
local m = gefs.open(dev):mount("main")
m:createfile("/README"); m:writefile("/README", "hello over 9p\n")
m:mkdir("/sub"); m:createfile("/sub/x"); m:writefile("/sub/x", "deep")

local respond = p9serve.responder(gefsfs.new(m))
local function rpc(bytes) return p9.decode(respond(bytes)) end

-- version + attach
ok(rpc(p9.tversion(0xffff, 8192, "9P2000")).version == "9P2000",
    "Tversion negotiates 9P2000")
ok(rpc(p9.tattach(1, 0, 0xffffffff, "glenda", "")).type == p9.Rattach,
    "Tattach roots a fid")

-- walk to a file, open, read its bytes
ok(#rpc(p9.twalk(2, 0, 2, { "README" })).wqid == 1, "Twalk reaches /README")
ok(rpc(p9.topen(3, 2, 0)).type == p9.Ropen, "Topen opens it")
ok(rpc(p9.tread(4, 2, 0, 4096)).data == "hello over 9p\n",
    "Tread returns the file's bytes")

-- a directory read: the entries come back as stat records
rpc(p9.tclone(6, 0, 5))
rpc(p9.topen(7, 5, 0))
local d = rpc(p9.tread(8, 5, 0, 8192))
local names, off = {}, 1
while off <= #d.data do
	local n2 = string.unpack("<I2", d.data, off)
	local st = p9.unpackstat(d.data:sub(off + 2, off + 1 + n2))
	names[st.name] = true
	off = off + 2 + n2
end
ok(names.README and names.sub and names.ctl,
    "a directory read lists its entries as stat records")

-- a nested walk in one message, then read
rpc(p9.twalk(9, 0, 9, { "sub", "x" }))
rpc(p9.topen(10, 9, 0))
ok(rpc(p9.tread(11, 9, 0, 100)).data == "deep",
    "a multi-element Twalk descends and reads")

-- a walk to nothing is an Rerror, not a crash
ok(rpc(p9.twalk(12, 0, 12, { "nope" })).type == p9.Rerror,
    "a walk to a missing name is an Rerror")

-- an unknown fid is refused
ok(rpc(p9.tstat(13, 99)).type == p9.Rerror, "an unknown fid is refused")

-- create a new file, write to it, read it back through a fresh walk
rpc(p9.tclone(20, 0, 20))
ok(rpc(p9.tcreate(21, 20, "new.txt", 0x1b6, 1)).type == p9.Rcreate,
    "Tcreate makes a new file")
ok(rpc(p9.twrite(22, 20, 0, "written via 9p")).type == p9.Rwrite,
    "Twrite to the created file")
rpc(p9.twalk(23, 0, 23, { "new.txt" }))
rpc(p9.topen(24, 23, 0))
ok(rpc(p9.tread(25, 23, 0, 100)).data == "written via 9p",
    "the created file reads back")

-- a directory (DMDIR in the perm), then a file created inside it: the
-- shape `tar xf` uses to populate a tree
rpc(p9.tclone(30, 0, 30))
ok(rpc(p9.tcreate(31, 30, "d", p9.DMDIR | 0x1ff, 0)).type == p9.Rcreate,
    "Tcreate with DMDIR makes a directory")
rpc(p9.twalk(32, 0, 32, { "d" }))
rpc(p9.tclone(33, 32, 33))
ok(rpc(p9.tcreate(34, 33, "inner", 0x1b6, 1)).type == p9.Rcreate,
    "a file can be created inside the new directory")
rpc(p9.twrite(35, 33, 0, "nested"))
rpc(p9.twalk(36, 0, 36, { "d", "inner" }))
rpc(p9.topen(37, 36, 0))
ok(rpc(p9.tread(38, 36, 0, 100)).data == "nested",
    "the nested file reads back through d/inner")

-- clone a FILE's fid with a zero-name walk, the way 9pfuse does before
-- every open -- a file is not a directory, so this must not be a "." walk
rpc(p9.twalk(40, 0, 40, { "README" }))
rpc(p9.tclone(41, 40, 41))
rpc(p9.topen(42, 41, 0))
ok(rpc(p9.tread(43, 41, 0, 100)).data == "hello over 9p\n",
    "a cloned file fid opens and reads (the 9pfuse path)")

-- Twstat: the rename 9P can express, and the fields it cannot apply.
rpc(p9.twalk(50, 0, 50, { "README" }))
ok(rpc(p9.twstat(51, 50, { name = "READYOU" })).type == p9.Rwstat,
    "Twstat renames within a directory")
ok(rpc(p9.twalk(52, 0, 52, { "READYOU" })).type == p9.Rwalk,
    "the file answers to its new name")
ok(rpc(p9.twalk(53, 0, 53, { "README" })).type == p9.Rerror,
    "and not to the old one")

-- the fid was not clunked by the rename, so it still names the file
ok(p9.unpackstat(rpc(p9.tstat(54, 50)).statbytes).name == "READYOU",
    "the fid follows the file to its new name")

-- a wstat that changes nothing a backend keeps is accepted, because
-- tar sets a mode and a time after every file it writes.
ok(rpc(p9.twstat(55, 50, { mode = 0x1ff, mtime = 1 })).type == p9.Rwstat,
    "a mode and time wstat is accepted and dropped")

ok(rpc(p9.twstat(56, 50, { name = "sub" })).type == p9.Rerror,
    "renaming onto a name in use is refused")
ok(rpc(p9.twstat(57, 999, { name = "x" })).type == p9.Rerror,
    "and a wstat on an unknown fid is Rerror")

io.write("1.." .. count .. "\n")
if failed > 0 then os.exit(1) end
