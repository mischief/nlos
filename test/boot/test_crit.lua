-- preemption cutting a thread in half.
--
-- The count hook stops a coroutine between two instructions of its
-- choosing, not of ours. For main that is harmless -- it yields the
-- whole proc and nothing else here runs -- but a THREAD cut mid-update
-- hands control to thread.run(), which then runs somebody else over
-- the top of a half-finished data structure. lib/thread marks those
-- updates (critenter/critleave) and run() resumes a cut thread, and
-- only it, until it is whole again.
--
-- Two ways it went wrong before that existed, both found on hardware
-- slow enough to be preempted often -- which is the whole difficulty
-- with this class of bug, since preemptions arrive per unit of WALL
-- time and the window is measured in instructions:
--
--   1. push() advancing _qtail before storing into _runq left a hole
--      that run() allocated past. pop() read the hole as "queue
--      empty" and the proc died "deadlock: all threads parked", or
--      the woken thread was simply lost.
--   2. Channel:recv looking, finding nothing, and only then joining
--      recvq: a sender in that gap woke an empty queue and left its
--      value in the buffer, and the receiver parked on a message that
--      had already arrived.
--
-- Neither is reachable on demand -- landing on one instruction is the
-- point -- so this leans on volume, and on the shapes most likely to
-- get cut: many threads sharing one channel, and a rendezvous where
-- every send must find its receiver.
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

-- ---- many senders and receivers over one buffered channel ----
--
-- Every value must arrive exactly once. A lost wake shows up as a
-- test that never finishes rather than one that fails, which is why
-- the harness timeout is part of this test.
local NSEND, NMSG = 5, 400

local ch = thread.chancreate(4)
local done = thread.chancreate(NSEND)
local got, sent = {}, 0

for s = 1, NSEND do
	thread.spawn(function()
		for i = 1, NMSG do
			ch:send({ from = s, seq = i })
		end
		done:send(true)
	end)
end

for _ = 1, 2 do
	thread.spawn(function()
		while true do
			local m = ch:recv()

			if m == nil then
				return
			end
			got[m.from] = (got[m.from] or 0) + 1
		end
	end)
end

thread.spawn(function()
	for _ = 1, NSEND do
		done:recv()
	end
	sent = NSEND * NMSG
	ch:close()
end)

thread.run()

tap.is(sent, NSEND * NMSG, "every sender finished")

local total, complete = 0, 0

for s = 1, NSEND do
	total = total + (got[s] or 0)
	if got[s] == NMSG then
		complete = complete + 1
	end
end
tap.is(total, NSEND * NMSG,
    ("every message arrived exactly once (%d)"):format(total))
tap.is(complete, NSEND, "and each sender's messages all arrived")

-- ---- rendezvous: no buffer to hide a lost wake ----
--
-- cap 0 means every send has to pair with a receiver directly, so the
-- deposit-and-wake path runs on every single message instead of only
-- when the buffer is full.
local rv = thread.chancreate(0)
local pairs_done = 0

thread.spawn(function()
	for i = 1, 400 do
		rv:send(i)
	end
	rv:close()
end)

thread.spawn(function()
	while true do
		local v, alive = rv:recv()

		if not alive then
			return
		end
		pairs_done = pairs_done + v - v + 1
	end
end)

thread.run()

tap.is(pairs_done, 400, "every rendezvous paired (" .. pairs_done .. ")")

-- ---- a thread cut while it is waking another ----
--
-- The ping-pong is the shape that found the original bug: a thread
-- doing nothing but waking a sibling and parking again, so that almost
-- all of its instructions are the wakeup path itself.
local a, b = thread.chancreate(1), thread.chancreate(1)
local laps = 0

thread.spawn(function()
	for _ = 1, 900 do
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

tap.is(laps, 900, "the ping-pong completed every lap (" .. laps .. ")")

-- and the scheduler is left in a consistent state: nothing still
-- marked mid-update, which would have run() resuming a corpse.
tap.ok(thread._crit == nil, "no thread left marked mid-update")

tap.done()
