-- the fat write path over a real mount: sectors cross mnt.lua,
-- dev.writeloop and a port, which host_fatwrite.lua cannot reach.
-- writes one file big enough to flush mid-write, reopens cold, and
-- verifies every file. constants must agree with boottest-microvm.lua.

local sys = require("los.sys")
local thread = require("los.thread")
local mnt = require("mnt")
local fat = require("fat")
local fatfs = require("fatfs")
local tap = require("tap")

tap.plan(10)

local NSEED = 24

local function seedname(i)
	return ("seed%02d.dat"):format(i)
end

local function seedcontent(i)
	return (("seed-%02d:"):format(i)):rep(100 + i * 97)
end

-- past 128 dirty sectors of 4096 bytes, so wrsec flushes mid-write
local function guestcontent()
	local parts = {}

	for k = 1, 40000 do
		parts[k] = ("guest line %08d\n"):format(k)
	end
	return table.concat(parts)
end

-- the device lib/fat wants: /dev/data as a seekable chan, wrapped by
-- gefs.io -- the shape the T-Deck's fatsrv had when task #47's volume
-- was corrupted. Every sector goes through chan positioning and
-- gefsio.wrap's write-count handling as well as the mount.
local gefsio = require("gefs.io")
local nsmod = require("ns")

local function device(right)
	local N = nsmod.new()

	assert(N:mount("/dev", mnt.new(right), "mnt",
	    { port = { __right = right } }))

	local ctl = N:readfile("/dev/ctl")
	local size = tonumber(ctl and ctl:match("bytes (%d+)"))

	if not size then
		local st = N:stat("/dev/data")

		size = st and st.size
	end

	local h = assert(N:open("/dev/data", "rw"))

	return gefsio.wrap(h, assert(size, "no device size"))
end

local function writefile(B, name, data)
	local h = B.create(B.attach(), name, "w")
	local off = 0

	while off < #data do
		local n = B.write(h, off, data:sub(off + 1, off + 8192))

		assert(n and n > 0, "short write")
		off = off + n
	end
	B.clunk(h)
end

-- nil rather than an error for a file a corrupted volume lost
local function readfile(B, name)
	local wok, h = pcall(B.walk, B.attach(), name)

	if not wok or not h then return nil end
	local o = B.open(h, "r")
	local out, off = {}, 0

	while true do
		local s = B.read(o, off, 8192)

		if not s or s == "" then break end
		out[#out + 1] = s
		off = off + #s
	end
	B.clunk(o)
	return table.concat(out)
end

local function checkseeds(B, label)
	local bad = 0

	for i = 1, NSEED do
		local got = readfile(B, seedname(i))
		local want = seedcontent(i)

		if got ~= want then
			bad = bad + 1
			if bad <= 3 then
				tap.diag(("%s: %s is %s bytes, wanted %d")
				    :format(label, seedname(i),
				    tostring(got and #got), #want))
			end
		end
	end
	tap.ok(bad == 0, ("%s: every seeded file is intact (%d bad)")
	    :format(label, bad))
end

local function main()
	local caps = sys.granted()

	if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
		tap.diag("no virtio-blk device; the rest cannot run")
		tap.done()
		return
	end

	local fs = fat.open(device(caps.blk), { cache = 128 })

	if not tap.ok(fs ~= nil, "the seeded volume opens as FAT") then
		tap.done()
		return
	end

	local B = fatfs.new(fs)

	checkseeds(B, "before")

	local data = guestcontent()

	writefile(B, "guest.dat", data)
	B.sync()
	tap.ok(true, ("wrote guest.dat (%d bytes) and synced"):format(#data))

	-- the bench that corrupted the board: remove first, rewrite, again
	local benchdata = ("bench line\n"):rep(6000)

	for _ = 1, 8 do
		local wok, h = pcall(B.walk, B.attach(), "bench.dat")

		if wok and h then B.remove(h) end
		writefile(B, "bench.dat", benchdata)
		B.sync()
	end
	tap.ok(readfile(B, "bench.dat") == benchdata,
	    "8 remove/rewrite rounds of a 64KB file")

	-- cold: a new mount, a new cache, nothing but what the disk holds
	local fs2 = fat.open(device(caps.blk), { cache = 128 })

	if not tap.ok(fs2 ~= nil, "the volume still opens after the write") then
		tap.done()
		return
	end

	local C = fatfs.new(fs2)
	local back = readfile(C, "guest.dat")

	tap.ok(back == data, ("guest.dat reads back (%s bytes, wanted %d)")
	    :format(tostring(back and #back), #data))

	checkseeds(C, "after")

	local rep = fs2:check()

	if type(rep) == "table" and #rep > 0 then
		for i = 1, math.min(#rep, 5) do
			tap.diag("check: " .. tostring(rep[i]))
		end
	end
	tap.ok(type(rep) ~= "table" or #rep == 0,
	    "the checker finds nothing wrong")

	tap.ok(true, "done")
	tap.done()
end

thread.spawn(main)
thread.run()
