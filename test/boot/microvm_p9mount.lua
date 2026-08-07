-- virtio-9p through the real namespace, not through raw 9P calls --
-- that is the whole point of this test. /lib/p9srv.lua is spawned at
-- boot as a PRIV_P9 driver, exactly like cons/wire/power, and grants a
-- "p9" capability the way espsrv.lua grants "esp". Mounting it is
-- ordinary mnt.lua/ns.lua work, the same mechanism the esp uses.
--
-- the host side is seeded by scripts/boottest-microvm.lua, which serves
-- a temporary directory holding hello.txt over -fsdev/virtio-9p-device.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(8)

local caps = sys.granted()

if not tap.ok(caps.p9 ~= nil, "a p9 capability was granted") then
	tap.diag("no virtio-9p device found; the rest cannot run")
	tap.done()
	return
end

local N = ns.new()
local mok, merr = N:mount("/host", mnt.new(caps.p9), "mnt",
    { port = { __right = caps.p9 } })

if not tap.ok(mok, "mounted virtio-9p at /host") then
	tap.diag("mount failed: " .. tostring(merr))
	tap.done()
	return
end

local data, rerr = N:readfile("/host/hello.txt")

if not tap.ok(data == "hello from 9p\n", "read /host/hello.txt through the mount") then
	tap.diag("got: " .. tostring(data or rerr))
end

-- a second, independent read: open() must not mutate the walked
-- handle, so two fids have to see the same content.
tap.ok(N:readfile("/host/hello.txt") == data,
    "a second independent open reads the same content")

local ents, derr = N:readdir("/host")
local names = {}

for _, e in ipairs(ents or {}) do
	names[#names + 1] = e.name
end
if not tap.ok(ents ~= nil, "readdir /host -> " .. table.concat(names, ",")) then
	tap.diag("readdir failed: " .. tostring(derr))
end

-- create: a new file through the mount, read back as a fresh open
-- (proving Tcreate wrote it rather than caching content locally) and
-- seen in readdir (proving it is a real host-visible file, not
-- open-only).
local wn, werr = N:writefile("/host/created.txt", "made by lua-os\n")

if wn then
	local rdata, rderr = N:readfile("/host/created.txt")

	if not tap.ok(rdata == "made by lua-os\n",
	    "a file created through the mount reads back") then
		tap.diag("got: " .. tostring(rdata or rderr))
	end

	local seen = false

	for _, e in ipairs(N:readdir("/host") or {}) do
		if e.name == "created.txt" then
			seen = true
		end
	end
	tap.ok(seen, "the created file appears in /host readdir")
else
	tap.ok(false, "create /host/created.txt: " .. tostring(werr))
	tap.ok(false, "the created file appears in /host readdir")
end

-- ---- 9p io does not stop the machine ----
--
-- The transport used to busy-wait for each reply, which on a
-- cooperative single-threaded kernel meant every other proc stopped for
-- the duration -- and a mount does a round trip per walk, read and
-- clunk. los.platform.p9's binding yields between polls now, so a proc
-- with nothing to do with the filesystem keeps running.
--
-- The assertion is that another proc got turns while the io below was
-- happening, so it counts ticks rather than merely surviving.
local counter = sys.newport("microvm_p9mount")
sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local n = 0

	while true do
		n = n + 1
		sys.send(a.__right, n)
		sys.yield()
	end
]], { arg = { __right = sys.sendright(counter) } })

local function ticks()
	local last = 0

	while true do
		local ok, v = sys.tryrecv(counter)

		if not ok then
			return last
		end
		last = v
	end
end

sys.yield()

local before = ticks()

for _ = 1, 20 do
	N:readfile("/host/hello.txt")
end

local after = ticks()

tap.diag(string.format("spinner ticks: %d before, %d after 20 reads",
    before, after))
tap.ok(after > before,
    "another proc ran during 9p io rather than being stalled by it")

tap.done()
