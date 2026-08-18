#!/usr/bin/env lua5.4
-- rename through lib/ns.lua, over every backend that can do it.
--
-- The same assertions run against the in-memory tree, a FAT volume and a
-- gefs one, because rename is the operation where the three differ most:
-- a table key, a directory entry, and a key that is (parent, name). The
-- cross-mount refusal needs two mounts, so it is checked separately.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path
-- dev.lua wants los.sys for MAXMSG only; no kernel here to give it one
package.loaded["los.sys"] = { MAXMSG = 8192 }
package.preload["los.thread"] = function()
	local function nope()
		error("host_rename: a local mount reached the scheduler", 0)
	end

	return {
		inthread = function() return false end,
		run = nope, chancreate = nope, spawn = nope,
	}
end

local dev = require("dev")
local ns = require("ns")
local fat = require("fat")
local fatfs = require("fatfs")
local gefs = require("gefs")
local gefsfs = require("gefsfs")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	io.write((cond and "ok " or "not ok ") .. count .. " - " .. name .. "\n")
	if not cond then
		failed = failed + 1
	end
	return cond
end

local function is(got, want, name)
	return ok(got == want,
	    ("%s (got %s, want %s)"):format(name, tostring(got), tostring(want)))
end

local function exists(N, path)
	return N:stat(path) ~= nil
end

-- ---- the backends, each with the same small tree in it ----

local function memfs()
	return dev.mem({
		a = "first",
		b = "second",
		sub = { x = "deep" },
		dir = {},
	})
end

local function fatvol()
	local d = fat.ram.new(4 * 1024 * 1024, 512)

	assert(fat.ream(d, { secsz = 512, label = "LUAOS" }))

	local fs = assert(fat.open(d, { cache = 64 }))

	assert(fs:writefile("/a", "first"))
	assert(fs:writefile("/b", "second"))
	assert(fs:mkdir("/sub"))
	assert(fs:writefile("/sub/x", "deep"))
	assert(fs:mkdir("/dir"))
	return fatfs.new(fs)
end

local function gefsvol()
	local d = gefs.ram.new(64 * 1024 * 1024, 16384)

	gefs.ream(d, { user = "glenda" })

	local m = gefs.open(d):mount("main")

	m:createfile("/a"); m:writefile("/a", "first")
	m:createfile("/b"); m:writefile("/b", "second")
	m:mkdir("/sub"); m:createfile("/sub/x"); m:writefile("/sub/x", "deep")
	m:mkdir("/dir")
	return gefsfs.new(m)
end

-- ---- the suite every backend answers the same way ----
--
-- crossdir says whether this backend moves an entry between two of its
-- own directories. gefs does not, because its wstat is shaped around
-- 9P's -- not because the format is in the way.
local function suite(label, build, crossdir)
	local function fresh()
		local N = ns.new()

		N:mount("/", build())
		return N
	end

	local N = fresh()

	ok(N:rename("/a", "/renamed"), label .. ": rename within a directory")
	ok(not exists(N, "/a"), label .. ": the old name is gone")
	is(N:readfile("/renamed"), "first", label .. ": the contents came along")

	N = fresh()

	local okr, err = N:rename("/sub/x", "/dir/x")

	if crossdir then
		ok(okr, label .. ": rename across directories")
		ok(not exists(N, "/sub/x"), label .. ": gone from the old one")
		is(N:readfile("/dir/x"), "deep", label .. ": arrived in the new")
	else
		ok(not okr, label .. ": refuses to move between directories")
		is(err, dev.Enotimpl, label .. ": and says so rather than Exdev")
		is(N:readfile("/sub/x"), "deep", label .. ": the source survives")
	end

	N = fresh()
	okr, err = N:rename("/a", "/b")
	ok(not okr, label .. ": renaming onto an existing name is refused")
	is(N:readfile("/b"), "second", label .. ": the target is untouched")
	is(N:readfile("/a"), "first", label .. ": and so is the source")

	okr = N:rename("/nosuch", "/x")
	ok(not okr, label .. ": renaming what is not there fails")

	okr = N:rename("/a", "/dir/../a")
	ok(okr, label .. ": a path is cleaned before it is judged a move")

	-- a directory, not just a file: FAT has to fix its ".." when one
	-- changes parent, and gefs has a super entry pointing back at it.
	N = fresh()
	ok(N:rename("/sub", "/moved"), label .. ": a directory renames too")
	is(N:readfile("/moved/x"), "deep", label .. ": and keeps its contents")
end

suite("ramfs", memfs, true)
suite("fat", fatvol, true)
suite("gefs", gefsvol, false)

-- ---- what no single backend can show ----

local N = ns.new()

N:mount("/", memfs())
N:mount("/other", dev.mem({ c = "elsewhere" }))

local okr, err = N:rename("/a", "/other/a")

ok(not okr, "cross-mount rename is refused")
is(err, dev.Exdev, "and says cross-device link")
ok(exists(N, "/a"), "the source survives a refusal")

-- a read-only mount offers neither method, so it refuses rather than
-- half-renames.
N = ns.new()
N:mount("/", dev.readonly(dev.mem({ a = "one", d = {} })))
ok(not N:rename("/a", "/z"), "a read-only mount refuses rename")
ok(not N:rename("/a", "/d/a"), "and refuses the cross-directory form too")

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
