-- the scheduler, cut between every pair of instructions.
--
-- sys.set_torture makes every instruction boundary in every thread a
-- preemption, so whatever the hook could land on, it lands on.
--
-- It was built to find races by exhaustion: a window between a thread
-- and thread.run is one or two instructions wide, and whether a test
-- run falls into one depended on how finely the work happened to be
-- cut -- which is set by the machine, since preemptions arrive per unit
-- of WALL time while the window is measured in instructions. That is
-- why those bugs turned up on an rpi4 and never on a desktop.
--
-- What it asks now is the opposite question. A thread is resumed in
-- place after being cut, so cutting one everywhere should not let
-- anything else observe it at all, and the first case below measures
-- exactly that. The rest are shapes that used to break, kept as
-- regressions.
--
-- The knob has to stay armed for any of this to mean anything, and
-- that is measured rather than assumed. Put the old behaviour back --
-- requeue a cut thread instead of resuming it in place -- and:
--
--	torture on	case 4 fails, and the run then hangs
--	torture off	nothing fails at all
--
-- So with the knob off this file passes against a scheduler that is
-- broken in the one way it exists to notice. Case 4 is the load
-- bearing one; it is the only thing in the tree that can tell whether
-- being cut is still different from being switched away from.
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

tap.plan(12)

tap.ok(sys.set_torture ~= nil, "sys.set_torture is present")

-- ---- cutting is not switching ----
--
-- The knob cuts a thread between every pair of its instructions. It
-- does not follow that anything else gets to run: run() puts the cut
-- thread straight back at the instruction it was cut at, so a thread
-- that neither parks nor yields is not interleaved with its siblings
-- however finely it is chopped.
--
-- That is the property everything below rests on, so it is measured
-- first rather than assumed. Two threads that never park: one handover
-- each, with the knob off and with it on. Before threads were resumed
-- in place this read 2 against 30, and the difference was every race
-- this file was written to find.
--
-- switches[id] is written only by the thread it belongs to, and `last`
-- is a single store, which under this scheduler is belt and braces --
-- but the rule is worth keeping in a file about scheduling.
local function handovers()
	local switches = { 0, 0 }
	local last = 0

	for id = 1, 2 do
		thread.spawn(function()
			for _ = 1, 30 do
				if last ~= id then
					switches[id] = switches[id] + 1
					last = id
				end
			end
		end)
	end
	thread.run()
	return switches[1] + switches[2]
end

local calm = handovers()

tap.ok(sys.set_torture(true), "and a boot payload may ask for it")

local cut = handovers()

tap.is(calm, 2, "untortured, a thread that never parks is not switched")
tap.is(cut, 2, "and cutting it everywhere does not switch it either")

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
--
-- Each receiver counts into its own slot. That is no longer load
-- bearing -- a shared total would survive this scheduler -- but a test
-- about scheduling should not be the thing that has to be reasoned
-- about when it fails.
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

-- ---- a thread body that returns something ----
--
-- Nothing reads the value, but lua_resume leaves it on the coroutine's
-- stack, and a finished coroutine holding one is indistinguishable
-- from an unstarted one by status and stack depth alike. Counting
-- deaths on that test misses these, so the count never reaches zero
-- and run() spins forever with nothing runnable. Reaching the line
-- below at all is the assertion; the tap is the record of it.
for i = 1, 4 do
	thread.spawn(function()
		thread.yield()
		return i, "and a second value"
	end)
end
thread.run()

tap.is(thread._n, 0, "a thread that returns a value is still counted dead")

-- ---- an allocator a caller wrote ----
--
-- `local f = next; next = next + 1` is lib/p9fs.lua's newfid and
-- lib/srv.lua's put, written out. It carries no guard of any kind, and
-- under the scheduler this file is about it does not need one: a thread
-- is not switched away from between the read and the store, however
-- finely it is cut. Under the one before it, this shape handed out 75
-- duplicates in 100.
local next_fid = 1
local mine = { {}, {}, {}, {} }

local function newfid()
	local f = next_fid

	next_fid = next_fid + 1
	return f
end

for id = 1, 4 do
	thread.spawn(function()
		local out = mine[id]

		for i = 1, 25 do
			out[i] = newfid()
		end
	end)
end

thread.run()

local seen, dups = {}, 0

for id = 1, 4 do
	for _, f in ipairs(mine[id]) do
		if seen[f] then
			dups = dups + 1
		end
		seen[f] = true
	end
end

tap.is(dups, 0, "an unguarded allocator hands out no number twice")

-- ---- a coroutine in the ring twice ----
--
-- _ready aimed at a thread that is staged but has not run yet finds it
-- unparked, takes the token path, and stages it again -- so main pushes
-- a second ring slot for a coroutine that already had one. Alive that
-- costs a lap and nothing else. Dead it is the whole proc: the second
-- slot resumes a corpse, resume_one's accounting runs twice for one
-- death, _n undercounts, and run() ends its loop leaving whatever is
-- still parked alive, suspended and uncounted -- no error, no deadlock
-- report, and a caller told the work is done.
--
-- The shape that finds it is a thread woken through one channel while
-- still queued on another, which is an alt over two -- lib/p9fs.lua's
-- flush does exactly this. The senders on the shared channel are what
-- make the second wake land in the window.
--
-- This one does not need the knob: it is about the order of a wake and
-- a park, which no amount of cutting changes, and it fails with torture
-- off just as readily. It lives here because the rounds above have
-- already paid for the threads.
local NALT, NROUND = 30, 5
local altfin, altwant = {}, 0

for round = 1, NROUND do
	local shared = thread.chancreate(1)

	for _ = 1, NALT do
		thread.spawn(function()
			shared:nbsend(true)
		end)
	end

	for id = 1, NALT do
		local slot = (round - 1) * NALT + id

		altwant = altwant + 1
		thread.spawn(function()
			local own = thread.chancreate(1)

			thread.spawn(function()
				own:send(true)
			end)
			thread.alt({ { c = own, op = "recv" },
			    { c = shared, op = "recv" } })
			altfin[slot] = true
		end)
	end
	thread.run()
end

local nalt = 0

for slot = 1, altwant do
	if altfin[slot] then
		nalt = nalt + 1
	end
end

tap.is(nalt, altwant, "every thread alting over two channels finished")
tap.is(thread._n, 0, "and none was abandoned alive and uncounted")

sys.set_torture(false)
tap.done()
