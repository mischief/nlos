-- Reading a stopped proc: frames, locals, upvalues, values by path.
-- The last assertion is the one that matters: reading must never run
-- target code, and a __tostring here has powered the machine off.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")

tap.plan(17)

local notice = sys.newport("test_dbgread.notice")

local src = table.concat({
	"local up = 'upvalue-here'",                    -- 1
	"local function frame(n, s)",                   -- 2
	"  local num, str = n * 2, s .. '!'",           -- 3
	"  local t = { a = 1, b = 'two',",              -- 4
	"      inner = { deep = 42 }, 10, 20 }",        -- 5
	"  local truth, nope = true, nil",              -- 6
	"  -- a metatable that must never fire",        -- 7
	"  local trap = setmetatable({}, {",            -- 8
	"      __index = function() fired = fired + 1 return 'BAD' end,",
	"      __tostring = function() fired = fired + 1 return 'BAD' end })",
	"  fired = 0",                                  -- 11
	"  local x = up",                               -- 12  <- breakpoint
	"  return num, str, t, truth, nope, trap, x",   -- 13
	"end",                                          -- 14
	"while true do frame(21, 'hi') end",            -- 15
}, "\n")

local pid, h = sys.spawn(src, { name = "dbgread" })

tap.ok(dbg.attach(pid, notice), "attach")
dbg.setbreak(pid, "dbgread", 12)

local m = thread.recvtimeout(notice, 3000)

tap.ok(m and m.line == 12, "stopped in the function (line " ..
    tostring(m and m.line) .. ")")

local co = m and m.co or 1

-- ---- coroutines and frames ----
local coros = dbg.coros(pid)

tap.ok(#coros >= 1 and coros[1].label == "main",
    "coros lists the main coroutine first")

local frames = dbg.frames(pid, co)

tap.ok(#frames >= 2, "frames reports the call and its caller (" ..
    #frames .. ")")
tap.ok(frames[1].line == 12, "the innermost frame is at the stop")
tap.ok(frames[1].source == "dbgread", "and names its source")

-- ---- locals ----
local locals = dbg.locals(pid, co, 0)
local by = {}

for _, l in ipairs(locals) do by[l.name] = l.value end

tap.ok(by.n and by.n.v == 21, "an integer local: " .. tostring(by.n and by.n.v))
tap.ok(by.num and by.num.v == 42, "a computed one: " ..
    tostring(by.num and by.num.v))
tap.ok(by.str and by.str.v == "hi!", "a string: " ..
    tostring(by.str and by.str.v))
tap.ok(by.truth and by.truth.v == true, "a boolean")
tap.ok(by.t and by.t.t == "table" and by.t.addr,
    "a table by type and address, not rendered")

-- keys are offered for navigation, raw
local keys = {}

for _, k in ipairs(by.t and by.t.keys or {}) do
	if k.v ~= nil then keys[tostring(k.v)] = true end
end
tap.ok(keys.a and keys.b, "its keys are listed for walking")

-- ---- upvalues ----
local ups = dbg.upvalues(pid, co, 0)
local sawup = false

for _, u in ipairs(ups) do
	if u.value and u.value.v == "upvalue-here" then sawup = true end
end
tap.ok(sawup, "the function's upvalue is readable")

-- ---- values by literal path ----
local v = dbg.get(pid, co, 0, "local", "t", { "b" })

tap.ok(v and v.v == "two", "a string key: " .. tostring(v and v.v))

v = dbg.get(pid, co, 0, "local", "t", { "inner", "deep" })
tap.ok(v and v.v == 42, "two hops: " .. tostring(v and v.v))

v = dbg.get(pid, co, 0, "local", "t", { 2 })
tap.ok(v and v.v == 20, "an integer key: " .. tostring(v and v.v))

-- ---- the rule that matters ----
-- everything above touched `trap`, which has an __index and a
-- __tostring that increment a global. Neither may have run.
dbg.get(pid, co, 0, "local", "trap", { "anything" })
dbg.locals(pid, co, 0)

local fired = dbg.get(pid, co, 0, "global", "fired")

tap.ok(fired and fired.v == 0,
    "no metamethod fired in the target (fired = " ..
    tostring(fired and fired.v) .. ")")

dbg.detach(pid)
sys.kill(pid)
sys.close(h)
sys.close(notice)
tap.done()
