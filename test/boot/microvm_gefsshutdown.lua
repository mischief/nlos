-- Graceful shutdown by the hangup cascade.
--
-- The point being proven: a served volume flushes on the way down with no
-- explicit sync, driven entirely by its clients leaving. The orchestrator
-- (this test, standing in for init) spawns gefssrv, writes through it
-- without ever asking for a commit, then shuts it down the graceful way --
-- drop every right to it, and its port hangs up, which the server takes
-- as "your work is done": it syncs and exits on its own. The orchestrator
-- watches for that exit and only then would it be safe to power off.
--
-- No sys.kill and no /ctl sync here: the write survives because dropping
-- the rights was enough. The host confirms it reached the disk
-- (boottest-microvm.lua --gefscommit), which is the half a guest cannot
-- see. This is the shape a real shutdown takes -- init drops the leaves,
-- the hangup flows down the mounts in dependency order, and each server
-- flushes as its clients vanish.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(4)

local GUEST = "written in the guest\n"		-- the host checks this landed

local function main()
	local caps = sys.granted()

	if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
		tap.diag("no virtio-blk device; the rest cannot run")
		tap.done()
		return
	end

	local code = io.open("/task/gefssrv.lua"):read("a")
	local gpid, g = sys.spawn(code, { name = "gefssrv" })
	sys.send(g, { blk = { __right = caps.blk }, label = "main",
	    syncms = 500 })

	local N = ns.new()
	assert(N:mount("/g", mnt.new(g), "mnt", { port = { __right = g } }))
	tap.ok(N:readfile("/g/hello") == "hello from gefs\n",
	    "the served volume reads")

	-- write and never sync: the bytes live in the server's cache
	N:writefile("/g/guest", GUEST)
	tap.ok(N:readfile("/g/guest") == GUEST,
	    "the write is visible through the server (in cache)")

	-- graceful shutdown: watch the server, then drop every right to it.
	-- unmount releases the mount's copy; close releases ours. With no
	-- senders left its port hangs up, and it flushes and exits on its own.
	sys.monitor(gpid)
	N:unmount("/g")
	sys.close(g)

	local m
	repeat
		m = thread.recv(sys.SELF)
	until type(m) == "table" and m.exit == gpid
	tap.ok(m.normal,
	    "the server drained and exited normally (not killed)")

	tap.done()
end

thread.spawn(main)
thread.run()
