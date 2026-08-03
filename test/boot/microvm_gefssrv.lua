-- gefs served, and hit by several clients at once.
--
-- task/gefssrv.lua stacks a gefs volume on the block device and serves it
-- with one worker, because the port is one thread of control with no
-- locks. This is the test that the one worker is enough: many clients
-- send at once, their requests interleave on the server's port (each
-- client yields at its own mnt round trip while the next runs), and the
-- server answers them one at a time. If it did not -- if two mutations of
-- the unlocked tree ran interleaved -- a client would read back something
-- other than what it wrote, or the seeded files would not survive.
--
-- The disk is the same host-reamed volume as microvm_gefs.lua (--gefs).

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(8)

local SMALL = "hello from gefs\n"
local BIG = ("gefs"):rep(10000)
local GUEST = "written in the guest\n"		-- the host checks this landed

-- what each client writes: distinct per (client, file), and big enough
-- that some span several gefs blocks so a write is several requests the
-- others can interleave between
local function content(c, j)
	return (("client-%d-file-%d:"):format(c, j)):rep(300 + c * j * 100)
end
local function path(c, j)
	return ("/g/c%d_%d"):format(c, j)
end

-- everything runs under thread.run(): the concurrent clients are spawned
-- coroutines, and a spawned coroutine is only driven by the scheduler,
-- not by a bare recv in the main body.
local function main()
	local caps = sys.granted()

	if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
		tap.diag("no virtio-blk device; the rest cannot run")
		tap.done()
		return
	end

	-- spawn the server and hand it the block device, dns.lua's pattern
	local code = io.open("/task/gefssrv.lua"):read("a")
	local _, g = sys.spawn(code, { name = "gefssrv" })
	-- a short sync interval so the shutdown flush lands quickly; the
	-- explicit /ctl sync below does not wait for it
	sys.send(g, { blk = { __right = caps.blk }, label = "main",
	    syncms = 500 })

	local N = ns.new()
	local mok, merr = N:mount("/g", mnt.new(g), "mnt",
	    { port = { __right = g } })

	if not tap.ok(mok, "mounted the gefs server at /g") then
		tap.diag("mount failed: " .. tostring(merr))
		tap.done()
		return
	end

	-- the served volume reads what the host reamed
	tap.ok(N:readfile("/g/hello") == SMALL, "read /g/hello through the server")
	tap.ok(N:readfile("/g/dir/big") == BIG, "read /g/dir/big through the server")

	-- ---- the storm ----

	local K, M = 4, 4		-- clients, files each
	local done = thread.chancreate(K)
	local results = {}

	for c = 1, K do
		thread.spawn(function()
			local ok = true
			for j = 1, M do
				local want = content(c, j)
				local wok = pcall(function()
					N:writefile(path(c, j), want)
				end)
				if not wok or N:readfile(path(c, j)) ~= want then
					ok = false
					break
				end
			end
			results[c] = ok
			done:send(true)
		end)
	end

	for _ = 1, K do done:recv() end

	local storm = true
	for c = 1, K do
		if not results[c] then storm = false end
	end
	tap.ok(storm, "every concurrent client wrote and read its own files")

	-- and it all survives a fresh read after the storm has settled
	local reread = true
	for c = 1, K do
		for j = 1, M do
			if N:readfile(path(c, j)) ~= content(c, j) then
				reread = false
			end
		end
	end
	tap.ok(reread, "every client's file re-reads correctly afterward")

	-- the files the host wrote were never touched and are still whole
	tap.ok(N:readfile("/g/hello") == SMALL,
	    "the seeded file survived the concurrent writes")

	-- persistence: commit a file through the server and force the sync
	-- explicitly by writing "sync" to the synthetic /ctl -- open it, do
	-- not writefile it, which would create a real file of that name. The
	-- host reopens the volume after the guest exits and checks /guest
	-- landed (boottest-microvm.lua --gefscommit).
	N:writefile("/g/guest", GUEST)
	local cf = N:open("/g/ctl", "w")
	local synced = cf and pcall(function()
		cf:write("sync")
		cf:close()
	end)
	tap.ok(synced, "forced a commit through /ctl")

	tap.done()
end

thread.spawn(main)
thread.run()
