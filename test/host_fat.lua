#!/usr/bin/env lua5.4
-- lib/fatfs.lua on the host, with nothing booted: the dev backend over
-- a volume in memory, run under the host's own lua the way
-- test/host_gefs.lua runs the gefs one.
--
-- The standalone fat tree keeps the exhaustive suite for the format
-- itself -- the three variants, long names, the checker, and interop
-- with fsck.fat and mtools. What is tested here is the part that only
-- exists in lua-os: that lib/fat loads under our loader, and that
-- lib/fatfs.lua maps it onto lib/dev.lua's interface correctly.
--
-- The length case has a test of its own below. fs:write grows the entry
-- it is handed and nothing else, so a backend that does not flush that
-- entry to its parent directory leaves a file whose bytes are on the
-- device and whose size still reads zero.
--
-- No dependency beyond lua5.4: lib/dev.lua wants los.sys for one
-- constant, which is stubbed rather than booted.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

-- the guest's own search path, so a module that resolves here resolves
-- on the board: one pattern, and a package is lib/NAME.lua beside
-- lib/NAME/.
package.path = scriptdir .. "/../lib/?.lua;" .. package.path

package.preload["los.sys"] = function()
	return { MAXMSG = 8192 }
end

-- lib/ns.lua reaches lib/chan.lua, which wants the scheduler for its
-- parallel walk. A local mount never takes that path -- there is no
-- port and nothing to wait on -- so this stubs the names rather than
-- booting a kernel, and says so loudly if one is ever reached.
package.preload["los.thread"] = function()
	local function nope()
		error("host_fat: a local mount reached the scheduler", 0)
	end

	return {
		inthread = function() return false end,
		run = nope, chancreate = nope, spawn = nope,
	}
end

local fat = require("fat")
local fatfs = require("fatfs")
local dev = require("dev")

--------------------------------------------------------------------------
-- TAP

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

local function diag(s)
	io.write("# " .. s .. "\n")
end

-- an op that must raise, and the message it raised
local function raises(fn, ...)
	local okk, err = pcall(fn, ...)

	return not okk, tostring(err)
end

--------------------------------------------------------------------------

local function newvol(mb)
	local d = fat.ram.new((mb or 8) * 1024 * 1024)
	local fs = assert(fat.ream(d, { label = "LUAOS" }))

	return fs, d
end

local fs, ramdev = newvol()
local B = fatfs.new(fs)

local root = B.attach()

ok(root ~= nil, "attach returns a handle")
ok(B.stat(root).dir, "the root is a directory")

-- ctl is synthetic and in the root listing
local names = {}

for _, e in ipairs(B.readdir(root)) do
	names[e.name] = e
end
ok(names["ctl"] ~= nil, "ctl appears in the root listing")

local ctlh = B.walk(root, "ctl")

ok(ctlh ~= nil, "ctl walks")
local ctltext = B.read(ctlh, 0, 4096)

ok(ctltext:match("sectorsize (%d+)") ~= nil, "ctl reports the sector size")
ok(ctltext:match("clustersize (%d+)") ~= nil, "and the cluster size")
ok(tonumber(ctltext:match("reads (%d+)")) ~= nil, "and a device read count")
-- an offset into it, since a client reads a file in pieces
ok(B.read(ctlh, 4, 6) == ctltext:sub(5, 10), "ctl reads at an offset")

-- create, write, read
local fh = B.create(root, "hello.txt", "rw", false)

ok(fh ~= nil, "create makes a file")

local msg = "the quick brown fox\n"

ok(B.write(fh, 0, msg) == #msg, "write reports the whole length")
ok(B.read(fh, 0, 512) == msg, "read gives back what was written")

-- the length case: the entry must have reached its parent directory.
-- Asked through a fresh walk rather than through the handle that wrote
-- it, because the handle holds no state and a stale directory entry is
-- exactly what would still look right otherwise.
local again = B.walk(root, "hello.txt")

ok(B.stat(again).size == #msg, "the size is on the device after a write")

-- and after a commit and a cold reopen of the same bytes
B.sync()

local fs2 = assert(fat.open(ramdev))
local B2 = fatfs.new(fs2)
local root2 = B2.attach()
local h2 = B2.walk(root2, "hello.txt")

ok(B2.stat(h2).size == #msg, "the size survives a reopen")
ok(B2.read(h2, 0, 512) == msg, "the bytes survive a reopen")

-- a short read at the end means end of file and nothing else
ok(B2.read(h2, #msg - 3, 512) == msg:sub(-3), "a read near the end is short")
ok(B2.read(h2, #msg, 512) == "", "a read at the end is empty")

-- writing at an offset extends the file
local ext = B2.walk(root2, "hello.txt")

B2.write(ext, #msg, "tail")
ok(B2.stat(B2.walk(root2, "hello.txt")).size == #msg + 4,
    "a write past the end extends the file")

-- directories
local dh = B2.create(root2, "bin", "rw", true)

ok(dh ~= nil, "create makes a directory")
ok(B2.stat(B2.walk(root2, "bin")).dir, "the directory reads back as one")

local sub = B2.walk(root2, "bin")
local prog = B2.create(sub, "smiley.lua", "rw", false)

B2.write(prog, 0, "return 1\n")
ok(B2.read(B2.walk(sub, "smiley.lua"), 0, 64) == "return 1\n",
    "a file in a subdirectory reads back")

-- walk semantics: a mount is a boundary
ok(B2.walk(root2, "..").path == "/", ".. at the root stays at the root")
ok(B2.walk(sub, "..").path == "/", ".. climbs to the parent")
ok(B2.walk(sub, ".").path == B2.walk(root2, "bin").path, ". stays put")

-- the errors dev clients act on
ok(raises(B2.walk, root2, "nope"), "walking a missing name raises")
ok(select(2, raises(B2.walk, root2, "nope")):find(dev.Enonexist, 1, true)
    ~= nil, "and raises Enonexist")
ok(raises(B2.walk, prog, "x"), "walking through a file raises")
ok(raises(B2.create, root2, "bin", "rw", false), "creating over a name raises")
ok(raises(B2.read, B2.walk(root2, "bin"), 0, 16), "reading a directory raises")
ok(raises(B2.remove, root2), "removing the root raises")

-- remove
B2.remove(B2.walk(sub, "smiley.lua"))
ok(raises(B2.walk, sub, "smiley.lua"), "a removed file is gone")

-- ---- through a namespace ----
--
-- The local-mount path, which is what an esp32 proc uses: the same
-- backend, reached by path rather than by handle. The served path
-- (lib/mnt.lua over a port) is a boot test's job, since it needs a
-- kernel to put a server on the other end.
local ns = require("ns")
local N = ns.new()

ok(N:mount("/", B2, "fatfs"), "the volume mounts")

-- writefile twice: create refuses a name that exists, so the second
-- has to go through open-for-write instead. The shorter body is the
-- case that matters -- without truncation the tail of the first is
-- still there, and what parses back is not what was written.
local long = ("return { ssid = %q }\n"):format("a-long-network-name")
local short = ("return { ssid = %q }\n"):format("s")

ok(N:writefile("/conf.lua", long) ~= nil, "writefile creates")
ok(N:readfile("/conf.lua") == long, "and the contents are right")
ok(N:writefile("/conf.lua", short) ~= nil, "writefile overwrites")

local back = N:readfile("/conf.lua")

ok(back == short, "the shorter body replaced the longer one")
if back ~= short then
	diag("got [" .. tostring(back) .. "]")
end

local conf = load(back or "", "=conf", "t", {})

ok(conf ~= nil and conf().ssid == "s", "and it parses back as written")

-- remove
ok(N:remove("/conf.lua"), "remove takes a file away")
ok(N:readfile("/conf.lua") == nil, "and it is gone")
ok(select(1, N:remove("/conf.lua")) == nil, "removing it again fails")

-- the volume is still coherent after all of that
B2.sync()

local problems = fs2:check()

if problems and #problems > 0 then
	for _, p in ipairs(problems) do
		diag("check: " .. tostring(p.what or p[1] or p))
	end
end
ok(problems == nil or #problems == 0, "the volume checks clean")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
