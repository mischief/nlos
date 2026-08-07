-- what a proc may do to another proc it holds no right to.
--
-- The line is between reading and acting. sys.stack, sys.trace and
-- sys.pidstat stay ambient with sys.procs and sys.name, which is
-- lib/procfs.lua's argument: a debugger is `cat /proc/4/stack`, and
-- what those report is structure rather than any proc's data.
--
-- Two things are on the other side. sys.set_trace WRITES -- it frees
-- and reallocates a ring the target's own hook is filling, and costs it
-- about 4.7x -- so it takes a right. And a death notice carries the
-- dying proc's own text in `reason`/`exitmsg`, which is its data; that
-- goes to a watcher that held a right when it asked to watch, decided
-- then rather than at death so the ordinary spawn-monitor-send-close
-- supervisor still hears how its child ended.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(8)

-- a proc we own, and a stranger that will be told its pid and nothing
-- else. the stranger gets a send right to us to report with.
local victim, vh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	thread.recv(sys.SELF)
	error("the victim's own words")
]], { name = "victim" })

local back = sys.sendright(sys.SELF)
local _, sh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...
	local out = a.reply.__right
	local t = a.target

	-- reads: ambient, and expected to work
	local okstack = pcall(sys.stack, t)
	local okstat = pcall(sys.pidstat, t)
	local okname = pcall(sys.name, t)
	-- a write to a proc we hold no right to
	local okarm, armerr = pcall(sys.set_trace, t, 64)

	-- watch it without holding a right, then say what we were told
	sys.monitor(t)
	sys.send(out, { probed = true, stack = okstack, stat = okstat,
	    name = okname, arm = okarm, armerr = tostring(armerr) })

	local m

	repeat
		m = thread.recv(sys.SELF)
	until type(m) == "table" and m.exit == t

	sys.send(out, { watched = true, normal = m.normal,
	    reason = m.reason })
]], { name = "stranger", arg = { target = victim,
    reply = { __right = back } } })

sys.close(back)

local m = thread.recv(sys.SELF)

tap.ok(m.stack, "a stranger may read another proc's stack")
tap.ok(m.stat and m.name, "and its pidstat and name")
tap.ok(not m.arm, "but may not arm a trace on it")
tap.ok(m.armerr:find("no right"), "and is told why: " .. m.armerr)

-- we hold the right, so we may arm it
tap.ok(pcall(sys.set_trace, victim, 64), "its owner may")

-- let the victim die. we monitored nothing yet, so do it now -- while
-- we still hold the right, which is what decides what we are told.
sys.monitor(victim)
sys.send(vh, "go")

local mine

repeat
	mine = thread.recv(sys.SELF)
until type(mine) == "table" and mine.exit == victim

tap.ok(mine.reason and mine.reason:find("the victim's own words"),
    "a holder is told why its proc died")

local theirs = thread.recv(sys.SELF)

tap.is(theirs.normal, false, "a stranger still learns that it died")
tap.is(theirs.reason, "", "but not what it said")

sys.close(sh)
tap.done()
