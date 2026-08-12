-- los.dbg: attaching to another proc, and the authority it takes.
--
-- Attaching is not observing. sys.stack reads a proc with no right at
-- all, because it reports structure; a debugger stops the proc and
-- reads its data, so it takes the same right sys.kill does -- or a
-- right to dbgport, which authorizes debugging anything and is what
-- makes a boot service reachable.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(11)

-- a target that will sit still: parked on a port nobody sends to.
local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.recv(sys.newport("test_dbg.park"))
]], { name = "dbgtarget" })

tap.ok(pid ~= nil, "the target proc spawned")
thread.sleep(50)

-- the notice port: where stops are reported. A right that cannot be
-- received on is refused, because a stop nobody reads strands a proc.
local notice = sys.newport("test_dbg.notice")

tap.ok(dbg.attach(pid, notice), "attach with the spawn right")

local st = dbg.status(pid)

tap.ok(st.attached, "status reports it attached")
tap.ok(not st.stopped, "and not stopped, having been asked for nothing")
tap.ok(st.debugger == sys.self(), "the debugger is named")

local ok, err = pcall(dbg.attach, pid, notice)

tap.ok(not ok, "a second debugger is refused: " .. tostring(err))

ok, err = pcall(dbg.attach, sys.self(), notice)
tap.ok(not ok, "a proc cannot debug itself: " .. tostring(err))

-- authority. A proc holding neither right may not attach, and the
-- refusal has to come from the kernel rather than from the module
-- being absent: los.dbg is ambient to require.
local probe = sys.newport("test_dbg.probe")
local ppid, ph = sys.spawn([[
	local a = ...
	local sys = require("los.sys")
	local dbg = require("los.dbg")
	local ok, err = pcall(dbg.attach, a.target, sys.SELF)

	sys.send(a.reply.__right, { ok = ok, err = tostring(err) })
]], { name = "dbgprobe",
      arg = { target = pid, reply = { __right = sys.sendright(probe) } } })

local m = thread.recvtimeout(probe, 2000)

tap.ok(m ~= nil, "the unprivileged prober answered")
if m then
	tap.ok(not m.ok, "it may not attach: " .. tostring(m.err))
else
	tap.ok(false, "it may not attach")
end

tap.ok(dbg.detach(pid), "detach")
tap.ok(not dbg.status(pid).attached, "status reports it gone")

sys.close(ph)
sys.close(h)
sys.close(probe)
sys.close(notice)
tap.done()
