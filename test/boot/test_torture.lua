-- the scheduler, cut between every pair of instructions.
--
-- test_crit covers the same ground by volume, and volume is a poor way
-- to ask this question: a race between a thread and thread.run is a
-- window of one or two instructions, so whether a run finds it depends
-- on how finely the work happens to be cut. That is why these bugs
-- turned up on an rpi4 and never on a desktop -- preemptions arrive per
-- unit of WALL time while the window is measured in instructions.
--
-- sys.set_torture takes the luck out: every instruction boundary in
-- every thread becomes a preemption, so every window is landed on. What
-- passes here is not "probably safe", it is "there was no instruction
-- at which being cut mattered" -- for the paths this exercises.
--
-- It has to be the kernel's hook. A lua debug hook cannot do it: ldblib
-- calls the hook function with lua_call, so a coroutine.yield() inside
-- one is always across a C-call boundary. Nothing in lua can reschedule
-- itself per instruction; only preempt_hook, which is C and already
-- yields, can.
--
-- Turn it on BEFORE spawning: lua_newthread copies hook, mask and count
-- from whoever created the coroutine, so threads are born tortured
-- rather than swept up afterwards.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

tap.ok(sys.set_torture ~= nil, "sys.set_torture is present")
tap.ok(sys.set_torture(true), "and a boot payload may ask for it")

-- ---- ping-pong: almost nothing but the wakeup path ----
--
-- Two threads handing a token back and forth, so nearly every
-- instruction either wakes a sibling or parks. Every one of those
-- instructions is now a preemption.
local a, b = thread.chancreate(1), thread.chancreate(1)
local laps, LAPS = 0, 40

thread.spawn(function()
	for _ = 1, LAPS do
		a:send(true)
		b:recv()
		laps = laps + 1
	end
	a:close()
end)

thread.spawn(function()
	while true do
		local _, alive = a:recv()

		if not alive then
			return
		end
		b:send(true)
	end
end)

thread.run()

tap.is(laps, LAPS, "the ping-pong completed every lap")

-- ---- several threads over one channel ----
--
-- The shape the 9p client had: more waiters than values, so the
-- register-then-park path runs constantly and every value must reach
-- exactly one receiver.
-- every count here is kept in the counting thread's own slot rather
-- than in one shared total. `got = got + 1` from three threads is the
-- very race this file exists to find: torture cuts between the read and
-- the store, increments are lost, and the test reports a failure of the
-- scheduler that is really a failure of its own bookkeeping. distinct
-- keys are safe because no two threads ever write the same one.
local ch = thread.chancreate(2)
local gotby = { 0, 0, 0 }
local NMSG = 40

thread.spawn(function()
	for i = 1, NMSG do
		ch:send(i)
	end
	ch:close()
end)

for id = 1, 3 do
	thread.spawn(function()
		while true do
			local _, alive = ch:recv()

			if not alive then
				return
			end
			gotby[id] = gotby[id] + 1
		end
	end)
end

thread.run()

tap.is(gotby[1] + gotby[2] + gotby[3], NMSG,
    "every message reached exactly one receiver")

-- ---- threads that spawn threads ----
--
-- spawn() counts the new thread in thread._n, which run() loops on. The
-- count is shared and the increment is a read-modify-write, so two
-- threads spawning at once can lose one: _n undercounts, run() decides
-- it is finished, and the threads it forgot are abandoned exactly where
-- they stand -- not deadlocked, nothing raised, and the caller told the
-- work is done. lib/srv.lua spawns a worker per request from a thread,
-- which is this shape.
--
-- Every child reports through its own slot, so what is counted here is
-- the scheduler's bookkeeping and never the test's.
local NPAR, NKID = 4, 10
local fin = {}

for p = 1, NPAR do
	thread.spawn(function()
		for k = 1, NKID do
			local id = (p - 1) * NKID + k

			thread.spawn(function()
				fin[id] = true
			end)
		end
	end)
end

thread.run()

local nfin = 0

for id = 1, NPAR * NKID do
	if fin[id] then
		nfin = nfin + 1
	end
end

tap.is(nfin, NPAR * NKID, "every thread spawned from a thread ran")
tap.is(thread._n, 0, "and the scheduler's count came back to zero")

sys.set_torture(false)
tap.ok(thread._crit == nil, "no thread left marked mid-update")

tap.done()
