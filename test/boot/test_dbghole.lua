-- What the debug capability must not hand back, and how it composes
-- with tracing. dbd1474 closed a leak of the kernel's lua_CFunction,
-- held as light userdata in every los.sys closure's upvalue 1; reading
-- another proc's upvalues reaches those same closures.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(8)

local notice = sys.newport("test_dbghole.notice")

-- a proc that parks inside a los.sys call, so its stack carries a C
-- frame for the reader to walk.
local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.recv(sys.newport("dbghole.park"))
]], { name = "dbghole" })

thread.sleep(50)
tap.ok(dbg.attach(pid, notice), "attach")
tap.ok(dbg.stop(pid), "stop it where it is blocked")

local stopped

for _ = 1, 200 do
	if sys.wchan(pid) == "stopped" then stopped = true break end
	thread.sleep(10)
end
tap.ok(stopped, "it stopped inside the block")

-- walk every frame of every coroutine, and every value they hold. No
-- light userdata may come back with an address.
local leaked, light, seen = nil, 0, 0

for _, c in ipairs(dbg.coros(pid)) do
	for _, f in ipairs(dbg.frames(pid, c.i)) do
		for _, which in ipairs({ "locals", "upvalues" }) do
			local ok, slots = pcall(dbg[which], pid, c.i, f.level)

			for _, s in ipairs(ok and slots or {}) do
				local v = s.value

				seen = seen + 1
				if v and v.light then
					light = light + 1
					if v.addr then leaked = s.name end
				end
			end
		end
	end
end

tap.diag(("%d values read, %d light userdata"):format(seen, light))
-- the walk has to REACH one, or it proves nothing: a los.sys closure
-- carries the kernel pointer in upvalue 1 and this is the frame for it.
tap.ok(light > 0, "the walk reached a los.sys closure's upvalues")
tap.ok(leaked == nil, "and no light userdata carries an address: " ..
    tostring(leaked))

dbg.detach(pid)
sys.kill(pid)
sys.close(h)

-- Tracing and the debugger want the same hook. proc_hookmask is the
-- one place the mask is computed, so turning one off cannot disarm the
-- other; both orders are tested.
local tpid, th = sys.spawn(table.concat({
	"local sys = require('los.sys')",         -- 1
	"local n = 0",                            -- 2
	"while true do n = n + 1 end",            -- 3  <- breakpoint
}, "\n"), { name = "dbgboth" })

thread.sleep(20)
sys.set_trace(tpid, 64)
dbg.attach(tpid, notice)
-- the half above left notices here -- a stop, then a death -- and on
-- another cpu they can still be queued. Drained before arming, so what
-- the wait below answers is the breakpoint.
while sys.tryrecv(notice) do end
dbg.setbreak(tpid, "dbgboth", 3)

local m = thread.recvtimeout(notice, 3000)

tap.ok(m and m.line == 3, "a breakpoint fires on a traced proc")

-- turning tracing off must leave the breakpoint armed
sys.set_trace(tpid, 0)
dbg.cont(tpid)
m = thread.recvtimeout(notice, 3000)
tap.ok(m and m.line == 3,
    "and still fires once tracing is turned off")

-- and the trace must survive the debugger leaving
sys.set_trace(tpid, 64)
dbg.detach(tpid)
thread.sleep(50)
tap.ok(#sys.trace(tpid) > 0, "the ring still fills after detach")

sys.set_trace(tpid, 0)
sys.kill(tpid)
sys.close(th)
sys.close(notice)
tap.done()
