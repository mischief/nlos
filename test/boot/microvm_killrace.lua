-- sys.kill against a proc running on another cpu.
--
-- proc_break drops the target's rights and frees its ports. A target
-- resumed on another cpu at that moment has C frames holding one of
-- those ports, so the kill must hold the proc still first. Rounds,
-- because the window is a resume: one kill can miss it.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

tap.ok(sys.stats().cpus > 1, "more than one cpu, so a target can run")

-- the victim never parks, so it is on a cpu whenever it is not
-- preempted, and it works ports the whole time: a kill landing inside
-- newport or close is what frees a port under its own frame.
local VICTIM = [[
	local sys = require("los.sys")

	while true do
		local p = sys.newport("killrace")
		local r = sys.sendright(p)

		sys.send(r, 1)
		sys.close(r)
		sys.close(p)
	end
]]

local ROUNDS = 60
local killed, notified = 0, 0

for _ = 1, ROUNDS do
	local pid = sys.spawn(VICTIM)

	sys.monitor(pid)

	-- let it reach the loop and land on a cpu before the kill
	thread.sleep(2)

	if sys.kill(pid) then
		killed = killed + 1
	end

	local note

	repeat
		local m = thread.recv(sys.SELF)

		if type(m) == "table" and m.exit == pid then
			note = m
		end
	until note

	if note.normal == false then
		notified = notified + 1
	end
	sys.reap(pid)
end

tap.is(killed, ROUNDS, "every victim was killed while running")
tap.is(notified, ROUNDS, "every death was notified, and the machine lived")
tap.done()
