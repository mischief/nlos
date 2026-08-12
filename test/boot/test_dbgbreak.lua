-- Breakpoints, in the main chunk and inside a thread.
--
-- The nested case is the one the machinery exists for. A yield only
-- reaches the resumer of the state it fired in, so a breakpoint inside
-- a lib/thread thread yields to thread.run and not to the kernel. The
-- walk-out forces the trip outward one level per instruction, and what
-- it buys is that the INNER state stays suspended exactly at the
-- breakpoint line with its frames standing, while the proc parks at the
-- kernel boundary. Continuing resumes that thread in place.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(18)

local notice = sys.newport("test_dbgbreak.notice")

-- ---- a plain loop in the main chunk ----
-- line numbers are load-bearing here, so the source is written with
-- them counted: the "mark" assignment below is line 4 of the chunk.
local src = table.concat({
	"local sys = require('los.sys')",          -- 1
	"local n = 0",                             -- 2
	"while true do",                           -- 3
	"  n = n + 1",                             -- 4  <- breakpoint
	"  for i = 1, 200 do n = n + i end",       -- 5
	"end",                                     -- 6
}, "\n")

local pid, h = sys.spawn(src, { name = "dbgloop" })

tap.ok(dbg.attach(pid, notice), "attach")

local id = dbg.setbreak(pid, "dbgloop", 4)

tap.ok(type(id) == "number", "setbreak returns an id")

local bps = dbg.breaks(pid)

tap.ok(#bps == 1 and bps[1].line == 4, "and breaks() lists it")

local m = thread.recvtimeout(notice, 3000)

tap.ok(m ~= nil, "the breakpoint was hit")
tap.ok(m and m.stop == "breakpoint", "reported as a breakpoint: " ..
    tostring(m and m.stop))
tap.ok(m and m.line == 4, "at the line asked for: " ..
    tostring(m and m.line))
-- the notice carries every field it claims: a miscounted pair count
-- drops the last one silently, and file is last.
tap.ok(m and m.file == "dbgloop", "and names the file: " ..
    tostring(m and m.file))
tap.ok(sys.wchan(pid) == "stopped", "and the proc is stopped")

local st = dbg.status(pid)

tap.ok(st.file == "dbgloop", "the file is named: " .. tostring(st.file))
tap.ok(st.bp == id, "and the breakpoint that did it")

-- hits are counted
dbg.cont(pid)
m = thread.recvtimeout(notice, 3000)
tap.ok(m ~= nil and m.line == 4, "it stops again on the next pass")
tap.ok(dbg.breaks(pid)[1].hits >= 2, "hits are counted (" ..
    dbg.breaks(pid)[1].hits .. ")")

-- clearing it lets the proc run
dbg.clearbreak(pid, id)
tap.ok(#dbg.breaks(pid) == 0, "clearbreak removes it")
dbg.cont(pid)
thread.sleep(100)
tap.ok(sys.wchan(pid) ~= "stopped", "and it runs on with none left")

dbg.detach(pid)
sys.kill(pid)
sys.close(h)

-- ---- a breakpoint inside a thread ----
local tsrc = table.concat({
	"local sys = require('los.sys')",          -- 1
	"local thread = require('los.thread')",    -- 2
	"local function work(n)",                  -- 3
	"  local x = n * 2",                       -- 4  <- breakpoint
	"  return x",                              -- 5
	"end",                                     -- 6
	"thread.spawn(function()",                 -- 7
	"  local t = 0",                           -- 8
	"  while true do",                         -- 9
	"    t = t + work(t)",                     -- 10
	"    thread.yield()",                      -- 11
	"  end",                                   -- 12
	"end)",                                    -- 13
	"thread.run()",                            -- 14
}, "\n")

local tpid, th = sys.spawn(tsrc, { name = "dbgthread" })

dbg.attach(tpid, notice)
dbg.setbreak(tpid, "dbgthread", 4)

m = thread.recvtimeout(notice, 3000)

tap.ok(m ~= nil and m.line == 4,
    "a breakpoint inside a thread stops the proc")

-- the coroutine it stopped in is not the main one: the walk-out left
-- the thread suspended at the line and parked the proc above it.
tap.ok(m and m.co and m.co > 1,
    "in a coroutine of its own (co " .. tostring(m and m.co) .. ")")

dbg.detach(tpid)
sys.kill(tpid)
sys.close(th)

-- ---- a coroutine created after the breakpoint was set ----
-- lua_newthread copies the hook from its creator once and never looks
-- again, so a state made after arming inherits the mask only because
-- every state of the proc is armed. This is the trap coreg.h names.
local lsrc = table.concat({
	"local sys = require('los.sys')",          -- 1
	"local function body()",                   -- 2
	"  local v = 1",                           -- 3  <- breakpoint
	"  coroutine.yield()",                     -- 4
	"end",                                     -- 5
	"local n = 0",                             -- 6
	"while true do",                           -- 7
	"  n = n + 1",                             -- 8
	"  if n > 200 then",                       -- 9
	"    local co = coroutine.create(body)",   -- 10
	"    coroutine.resume(co)",                -- 11
	"  end",                                   -- 12
	"end",                                     -- 13
}, "\n")

local lpid, lh = sys.spawn(lsrc, { name = "dbglate" })

dbg.attach(lpid, notice)
dbg.setbreak(lpid, "dbglate", 3)

m = thread.recvtimeout(notice, 5000)

tap.ok(m and m.line == 3,
    "a breakpoint fires in a coroutine created after it was set")
tap.ok(m and m.co and m.co > 1,
    "in the new coroutine (co " .. tostring(m and m.co) .. ")")

dbg.detach(lpid)
sys.kill(lpid)
sys.close(lh)
sys.close(notice)
tap.done()
