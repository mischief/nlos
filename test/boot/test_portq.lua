-- a recv waiter is registered a bounded number of times, however often
-- it re-parks.
--
-- The scheduler notes who is in recv() on which port so a message can
-- be handed straight over. Only a delivered message takes an entry off
-- again, and recv() is a loop: a wake that delivers nothing sends the
-- same thread back to register a second time. Nothing then shortens the
-- list, and the entries are strong references, so a long-lived server
-- on a quiet port would hold every coroutine that ever waited there.
--
-- The count is read only after a sleep, with every other thread parked.
-- Read at any other moment it is a race: a thread the scheduler has
-- woken but not yet resumed is off the list and belongs off it.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

local NTHREAD = 4
local ROUNDS = 30

-- One entry per waiting thread. The spare allows for a thread in
-- flight, since the poking thread below is registered on its own port
-- for part of every round.
local CAP = NTHREAD + 1

local ports, rights = {}, {}

for i = 1, NTHREAD do
	ports[i] = sys.newport("test_portq")
	rights[i] = sys.sendright(ports[i])
end

-- the one port that gets traffic. The others stay quiet, so their
-- threads re-park without ever taking a message.
local poke = sys.newport("test_portq.p")
local pokeright = sys.sendright(poke)
local stop = false

for i = 1, NTHREAD do
	thread.spawn(function()
		while not stop do
			thread.recv(ports[i])
		end
	end)
end

thread.spawn(function()
	thread.sleep(50)		-- everyone else parked
	local settled = thread._nwaiters

	tap.ok(settled >= NTHREAD and settled <= CAP,
	    ("%d entries for %d waiting threads"):format(settled, NTHREAD))

	for _ = 1, ROUNDS do
		sys.send(pokeright, "poke")
		thread.recv(poke)
	end

	thread.sleep(50)		-- and parked again
	local after = thread._nwaiters

	-- the count is a property of how many threads are waiting, not of
	-- how many times they have parked
	tap.ok(after <= CAP,
	    ("%d rounds of wakes later it is still %d, at most %d")
	    :format(ROUNDS, after, CAP))
	tap.ok(after <= settled + 1,
	    ("and it did not grow (%d -> %d)"):format(settled, after))

	-- each one wakes on a real message, sees the flag and returns
	stop = true
	for i = 1, NTHREAD do
		sys.send(rights[i], "done")
	end
end)

thread.run()

-- ---- and again, with every thread on ONE port ----
--
-- The list case, which the run above never reaches: a port with one
-- waiter is a scalar. Two threads on one port take turns being its last
-- entry, so a check that asked only about the tail would find the other
-- thread there and append, and the list would grow by one per thread on
-- every wake that delivered nothing.
local shared = sys.newport("test_portq.shared")
local sharedright = sys.sendright(shared)

stop = false

for _ = 1, NTHREAD do
	thread.spawn(function()
		while not stop do
			thread.recv(shared)
		end
	end)
end

thread.spawn(function()
	thread.sleep(50)
	local settled = thread._nwaiters

	for _ = 1, ROUNDS do
		sys.send(pokeright, "poke")
		thread.recv(poke)
	end

	thread.sleep(50)
	local after = thread._nwaiters

	tap.ok(after <= settled + 1,
	    ("%d threads on one port, %d rounds: %d -> %d entries")
	    :format(NTHREAD, ROUNDS, settled, after))

	stop = true
	for _ = 1, NTHREAD do
		sys.send(sharedright, "done")
	end
end)

thread.run()

sys.close(sharedright)
sys.close(shared)
for i = 1, NTHREAD do
	sys.close(rights[i])
	sys.close(ports[i])
end
tap.done()
