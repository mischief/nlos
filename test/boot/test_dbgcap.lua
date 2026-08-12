-- The debug capability, and the orphan case. A right to dbgport debugs
-- anything, which is the point: nothing holds a right to a boot service
-- but init, so otherwise the procs most worth debugging cannot be.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(7)

local caps = sys.granted()

tap.ok(caps.dbg ~= nil, "the kernel granted proc 0 a dbg capability")

-- a proc this test does not own: spawned by a child, so no right to it
-- reaches here.
local relay = sys.newport("test_dbgcap.relay")
local rpid, rh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...
	local pid = sys.spawn("while true do end", { name = "grandchild" })

	sys.send(a.reply.__right, { pid = pid })
	thread.recv(sys.SELF)
]], { name = "parent",
      arg = { reply = { __right = sys.sendright(relay) } } })

local m = thread.recvtimeout(relay, 2000)
local orphanpid = m and m.pid

tap.ok(orphanpid ~= nil, "a grandchild exists that we hold no right to")

-- without the capability this would be refused; the boot proc holds it
local notice = sys.newport("test_dbgcap.notice")
local ok, err = pcall(dbg.attach, orphanpid, notice)

tap.ok(ok, "the dbg capability reaches it: " .. tostring(err))
tap.ok(dbg.stop(orphanpid), "and can stop it")

local stopped

for _ = 1, 200 do
	if sys.wchan(orphanpid) == "stopped" then stopped = true break end
	thread.sleep(10)
end
tap.ok(stopped, "it stopped")

-- ---- the orphan case ----
-- A debugger that dies must not strand its target: the target holds no
-- right to it and, being stopped, is not running to notice.
local dpid, dh = sys.spawn([[
	local sys = require("los.sys")
	local dbg = require("los.dbg")
	local a = ...
	local port = sys.newport("victim.notice")

	dbg.attach(a.target, port)
	dbg.stop(a.target)
	sys.send(a.reply.__right, { stopped = true })
	while true do end
]], { name = "dyingdbg",
      arg = { target = orphanpid, reply = { __right = sys.sendright(relay) },
	      dbg = { __right = caps.dbg } } })

-- our own attachment has to go first: one debugger per proc
dbg.detach(orphanpid)

local waited = thread.recvtimeout(relay, 3000)

tap.ok(waited and waited.stopped, "a second debugger took it and stopped it")

-- kill the debugger and watch the target come back
sys.kill(dpid)

local freed

for _ = 1, 300 do
	if sys.wchan(orphanpid) ~= "stopped" then freed = true break end
	thread.sleep(10)
end
tap.ok(freed, "killing the debugger released the target (" ..
    tostring(sys.wchan(orphanpid)) .. ")")

sys.kill(rpid)
sys.close(rh)
sys.close(dh)
sys.close(relay)
sys.close(notice)
tap.done()
