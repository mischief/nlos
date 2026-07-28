-- the repl's bare-word magic (lib/ps.lua). the load-bearing property:
-- ps and stats only report, halt has a real side effect, and therefore
-- halt must NOT fire from __tostring.
local sys = require("los.sys")
local magic = require("ps")
local tap = require("tap")

tap.plan(5)

-- ---- the reporting ones are pure and safe to traverse ----
tap.ok(tostring(magic.ps):find("PID") ~= nil, "ps renders a table with a header")
tap.ok(tostring(magic.stats):find("procs=") ~= nil, "stats renders counters")

-- ---- halt explains itself when printed, and does not fire ----
local power = sys.granted().power
local halt = magic.halt(power)
local shown = tostring(halt)

tap.ok(shown:find("halt%(%)") ~= nil,
    "printing halt explains how to use it: " .. shown)

-- the regression that matters: a generic traversal that tostrings every
-- value must not power the machine off. this is `pairs(_G)` in
-- miniature, and it used to be fatal.
local env = { ps = magic.ps, stats = magic.stats, halt = halt, n = 1 }
local seen = 0

for _, v in pairs(env) do
    local _ = tostring(v)
    seen = seen + 1
end
tap.ok(seen == 4, "traversing a table of magic values tostrings all of them")

-- if we are still executing, __tostring did not shut us down
tap.ok(true, "still running after tostring'ing halt")

tap.done()
