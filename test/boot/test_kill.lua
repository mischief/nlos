-- sys.kill: the backstop for a proc that will not stop on its own.
--
-- The cooperative shutdown is the hangup cascade (test_gefsshutdown and
-- lib/gefs): drop the rights and a proc watching its port exits. A proc
-- that watches nothing -- a bare loop -- never sees it, so this is how a
-- shutdown reclaims it. A killed proc becomes a corpse exactly as a crash
-- does: its monitors are told, and it is held BROKE until reaped.
--
-- The authority is a right to the target's self port, which sys.spawn
-- returns to the parent. A pid alone is not enough, and sys.procs hands
-- out pids to anyone -- so the last case here is a proc holding a pid it
-- has no right to.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(9)

-- a proc that never parks; only preemption and a kill can stop it
local pid = sys.spawn([[ while true do end ]])

tap.ok(pid ~= nil, "spawned a runaway proc")

sys.monitor(pid)
tap.ok(sys.kill(pid) == true, "sys.kill stops it and reports so")

-- the death is delivered to the monitor at once, like any exit
local note
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == pid then note = m end
until note
tap.ok(note ~= nil, "the killed proc's death was notified")
tap.ok(note.normal == false, "a killed proc is not a normal exit")

-- it is already gone: a second kill finds nothing to do
tap.ok(sys.kill(pid) == false, "killing an already-dead proc is a no-op")

-- self is refused: freeing the caller mid-syscall is not on offer
tap.ok(not (pcall(sys.kill, sys.self())), "killing self is refused")

-- a pid without a right to it. the victim is spawned here, so this proc
-- may kill it; the assassin is told the pid and given nothing else.
local victim = sys.spawn([[ while true do end ]])
-- a send right to our own port, so the assassin can report back. that is
-- the only right it gets, and pointedly not one to the victim.
local back = sys.sendright(sys.SELF)
local _, ah = sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local ok, err = pcall(sys.kill, a.target)

	sys.send(a.reply.__right, { tried = true, ok = ok,
	    err = tostring(err) })
]], { arg = { target = victim, reply = { __right = back } } })

-- rights are copied, not moved: the child has its own now
sys.close(back)

local said
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.tried then said = m end
until said

tap.ok(said.ok == false, "a proc with no right to a pid cannot kill it")
tap.ok(said.err:find("no right"), "and is told why: " .. said.err)
tap.ok(sys.kill(victim) == true, "its parent still can")

sys.close(ah)
tap.done()
