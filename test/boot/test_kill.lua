-- sys.kill: the backstop for a proc that will not stop on its own.
--
-- The cooperative shutdown is the hangup cascade (test_gefsshutdown and
-- lib/gefs): drop the rights and a proc watching its port exits. A proc
-- that watches nothing -- a bare loop -- never sees it, so this is how a
-- shutdown reclaims it. A killed proc becomes a corpse exactly as a crash
-- does: its monitors are told, and it is held BROKE until reaped.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

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

tap.done()
