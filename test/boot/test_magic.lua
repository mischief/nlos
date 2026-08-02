-- the repl's bare-word magic (lib/ps.lua). the load-bearing property:
-- ps and stats only report, halt has a real side effect, and therefore
-- halt must NOT fire from __tostring.
local sys = require("los.sys")
local magic = require("ps")
local tap = require("tap")

tap.plan(11)

-- ---- the reporting ones are pure and safe to traverse ----
tap.ok(tostring(magic.ps):find("PID") ~= nil, "ps renders a table with a header")
tap.ok(tostring(magic.stats):find("procs=") ~= nil, "stats renders counters")
tap.ok(tostring(magic.ports):find("DROPF") ~= nil,
    "ports renders a table with a header")

-- ---- halt explains itself when printed, and does not fire ----
local power = sys.granted().power
local halt = magic.halt(power)
local shown = tostring(halt)

tap.ok(shown:find("halt%(%)") ~= nil,
    "printing halt explains how to use it: " .. shown)

-- the regression that matters: a generic traversal that tostrings every
-- value must not power the machine off. this is `pairs(_G)` in
-- miniature, and it used to be fatal.
local env = { ps = magic.ps, stats = magic.stats, ports = magic.ports,
    halt = halt, n = 1 }
local seen = 0

for _, v in pairs(env) do
    local _ = tostring(v)
    seen = seen + 1
end
tap.ok(seen == 5, "traversing a table of magic values tostrings all of them")

-- if we are still executing, __tostring did not shut us down
tap.ok(true, "still running after tostring'ing halt")

-- ---- cross-proc stack reading ----
local thread = require("los.thread")
local pid = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	local function inner(p)
		thread.recv(p)
	end

	inner(sys.newport())
]], { name = "wedged" })

thread.sleep(200)

-- sys.stack reports one entry per coroutine (src/debug.c). This proc has
-- no threads, so everything is in the first, its own.
local coros = sys.stack(pid)

tap.ok(#coros >= 1, "the wedged proc reports at least its own coroutine")

local frames = coros[1].frames

tap.ok(#frames >= 3, "a wedged proc has a readable stack (" .. #frames ..
    " frames)")
tap.ok(frames[1].source == "[C]",
    "innermost frame is the C block call (" .. frames[1].source .. ")")

local named = false

for _, f in ipairs(frames) do
	if f.name == "inner" then
		named = true
	end
end
tap.ok(named, "and the lua function names come through")

-- reading a stack must not disturb the target: it should still be
-- blocked in the same place afterwards, with the same depth
local again = sys.stack(pid)

tap.is(#again[1].frames, #frames,
    "reading a stack twice is stable and side-effect free")

tap.done()
