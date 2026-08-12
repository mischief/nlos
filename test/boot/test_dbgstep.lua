-- Stepping: one line at a time, and over a call. "over" waits for the
-- frame depth to come back down, so a call is executed rather than
-- entered; "out" is the same with one frame less.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(8)

local notice = sys.newport("test_dbgstep.notice")

local src = table.concat({
	"local function inner(a)",                 -- 1
	"  local b = a + 1",                       -- 2
	"  return b",                              -- 3
	"end",                                     -- 4
	"local t = 0",                             -- 5
	"while true do",                           -- 6
	"  t = t + 1",                             -- 7  <- breakpoint
	"  t = inner(t)",                          -- 8
	"  t = t + 1",                             -- 9
	"end",                                     -- 10
}, "\n")

local pid, h = sys.spawn(src, { name = "dbgstep" })

tap.ok(dbg.attach(pid, notice), "attach")
dbg.setbreak(pid, "dbgstep", 7)

local m = thread.recvtimeout(notice, 3000)

tap.ok(m and m.line == 7, "stopped at the breakpoint (line " ..
    tostring(m and m.line) .. ")")

-- one step "in" from line 7 lands on line 8
dbg.step(pid, "in")
m = thread.recvtimeout(notice, 3000)
tap.ok(m and m.line == 8, "step in reaches the next line (" ..
    tostring(m and m.line) .. ")")
tap.ok(m and m.stop == "step", "and says why: " .. tostring(m and m.stop))

-- line 8 calls inner(). "in" enters it.
dbg.step(pid, "in")
m = thread.recvtimeout(notice, 3000)
tap.ok(m and m.line == 2, "step in enters the call (" ..
    tostring(m and m.line) .. ")")

-- "out" from inside inner returns to the caller's frame
dbg.step(pid, "out")
m = thread.recvtimeout(notice, 3000)
tap.ok(m and (m.line == 8 or m.line == 9),
    "step out comes back to the caller (" .. tostring(m and m.line) .. ")")

-- from the caller, "over" must not stop inside inner: the next stop is
-- in the loop body, not at line 2 or 3.
dbg.clearbreak(pid, 0)
local st = dbg.status(pid)

tap.ok(st.stopped, "still stopped with no breakpoints left")

local sawinner = false

for _ = 1, 6 do
	dbg.step(pid, "over")
	m = thread.recvtimeout(notice, 3000)
	if not m then break end
	if m.line == 2 or m.line == 3 then sawinner = true end
end
tap.ok(not sawinner, "step over never stops inside the call")

dbg.detach(pid)
sys.kill(pid)
sys.close(h)
sys.close(notice)
tap.done()
