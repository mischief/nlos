local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(5)

-- init holds sys.SCHED at boot
local ok = pcall(sys.set_priority, sys.self(), 4)
tap.ok(ok, "init can set_priority (holds SCHED)")
tap.is(sys.priority(sys.self()), 4, "weight took effect")

-- clamp
sys.set_priority(sys.self(), 9999)
tap.is(sys.priority(sys.self()), 16, "weight clamps to MAXWEIGHT")
sys.set_priority(sys.self(), 1)

-- an ordinary spawn child has no SCHED right
local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local ok, err = pcall(sys.set_priority, sys.self(), 16)
	sys.send(m.reply.__right, { ok = ok, err = tostring(err) })
]], { name = "victim" })
local rp = sys.newport()
sys.send(h, { reply = { __right = rp } })
local r = thread.recv(rp)
tap.ok(not r.ok, "spawn child denied set_priority")
tap.ok(r.err:find("no scheduling capability") ~= nil,
    "denied with the right error: " .. r.err)

tap.done()
