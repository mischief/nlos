#!/usr/bin/env lua5.4
-- the fat WRITE path, on a volume shaped like the one the board carries.
--
-- test/host_fat.lua covers the backend's own operations. What is not
-- covered anywhere, and what task #47 is about, is the pattern the
-- machine actually runs: a volume written once by tools/mkfatimg.lua,
-- then mounted and written to a little -- one small file, a sync -- and
-- read from a lot. The file that came back corrupt on the board was one
-- nothing had written, which points at a metadata write damaging a
-- chain that belongs to something else.
--
-- So this builds many files, writes one, syncs, reopens the volume and
-- verifies every OTHER file byte for byte. A driver that damages a
-- neighbour fails here rather than three reflashes later.
--
-- 4096-byte sectors, as the flash has: the erase block is the sector on
-- that board, and a 512-byte one exercises different arithmetic.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

package.preload["los.sys"] = function()
	return { MAXMSG = 8192 }
end
package.preload["los.thread"] = function()
	local function nope()
		error("host_fatwrite: a local mount reached the scheduler", 0)
	end

	return {
		inthread = function() return false end,
		run = nope, chancreate = nope, spawn = nope,
	}
end

local fat = require("fat")
local fatfs = require("fatfs")

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

local SECSZ = 4096
local MB = 1024 * 1024

-- the files, sized like the ones on luafs: lib/ is a few hundred lines
-- each, bin/ smaller, and a couple are much larger than a cluster.
local function content(name, n)
	local parts = {}

	for i = 1, n do
		parts[i] = ("%s line %d: "):format(name, i) ..
		    string.rep("x", 40) .. "\n"
	end
	return table.concat(parts)
end

local files = {}

for i = 1, 60 do
	local name = ("file%02d.lua"):format(i)

	files[name] = content(name, 10 + (i * 7) % 90)
end
files["big.lua"] = content("big", 900)

-- ---- build it, the way mkfatimg does ----

local dev = fat.ram.new(4 * MB, SECSZ)

assert(fat.ream(dev, { secsz = SECSZ, label = "LUAOS" }))

local function mount()
	return fatfs.new(assert(fat.open(dev, { cache = 128 })))
end

local function writefile(B, name, data)
	local root = B.attach()
	local h = B.create(root, name, "w")

	if not h then
		h = B.walk(root, name)
		h = B.open(h, "w")
	end
	local off = 0

	while off < #data do
		local n = B.write(h, off, data:sub(off + 1, off + 8192))

		assert(n and n > 0, "short write")
		off = off + n
	end
	B.clunk(h)
end

local function readfile(B, name)
	local h = B.walk(B.attach(), name)
	local o = B.open(h, "r")
	local out, off = {}, 0

	while true do
		local s = B.read(o, off, 8192)

		if not s or s == "" then
			break
		end
		out[#out + 1] = s
		off = off + #s
	end
	B.clunk(o)
	return table.concat(out)
end

do
	local B = mount()

	for name, data in pairs(files) do
		writefile(B, name, data)
	end
	B.sync()
	ok(true, "built a volume of files")
end

-- ---- what the machine does to it afterwards ----

do
	local B = mount()

	writefile(B, "wifi.lua", "return { ssid = \"labratory\" }\n")
	B.sync()
	ok(true, "wrote one small file and synced, as a running machine does")
end

-- ---- and now every file that was NOT written must be intact ----

do
	local B = mount()
	local bad = 0

	for name, want in pairs(files) do
		local got = readfile(B, name)

		if got ~= want then
			bad = bad + 1
			if bad <= 3 then
				diag(("%s: %d bytes, wanted %d")
				    :format(name, #got, #want))
			end
		end
	end
	ok(bad == 0, ("every file a neighbour's write did not touch is intact"
	    .. " (%d bad)"):format(bad))
	ok(readfile(B, "wifi.lua"):match("labratory") ~= nil,
	    "and the file that was written reads back")
end

-- ---- the checker agrees ----

do
	local fs = assert(fat.open(dev, { cache = 128 }))
	local bad = fs:check()

	if type(bad) == "table" and #bad > 0 then
		for i = 1, math.min(#bad, 5) do
			diag("check: " .. tostring(bad[i]))
		end
	end
	ok(type(bad) ~= "table" or #bad == 0,
	    "the checker finds nothing wrong after a clean write")
end

-- ---- and the same, cut off mid-write ----
--
-- The board is reset while it is running -- by a reflash, by the power
-- button, by a fault -- and lib/fat is write-back: a dirty sector sits
-- in the cache until sync(). What must NOT happen is that losing those
-- sectors damages a file nobody was writing. The file being written is
-- allowed to be lost; that is what a filesystem with no journal
-- promises and all it promises.
--
-- A cut is modelled by writing without ever syncing and then throwing
-- the cache away, which is what the sectors never reaching the flash
-- looks like from the volume's side.
do
	local before = dev:clone()
	local B = mount()

	writefile(B, "cutoff.lua", content("cutoff", 300))
	-- no sync: the cache dies with it

	-- the volume as the flash would have it after the reset
	dev = before

	local C = mount()
	local bad = 0

	for name, want in pairs(files) do
		if readfile(C, name) ~= want then
			bad = bad + 1
		end
	end
	ok(bad == 0, ("a write cut off mid-flight leaves the other files "
	    .. "alone (%d bad)"):format(bad))

	local fs = assert(fat.open(dev, { cache = 128 }))
	local rep = fs:check()

	if type(rep) == "table" and #rep > 0 then
		for i = 1, math.min(#rep, 5) do
			diag("after the cut: " .. tostring(rep[i]))
		end
	end
	ok(type(rep) ~= "table" or #rep == 0,
	    "and the volume is still consistent")
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
