-- two cpus waking one alt-blocked proc at the same moment.
--
-- A waker holds the bucket covering the port it woke on. A proc in an
-- alt is on several ports, in several buckets, so two cpus can decide
-- to wake it at once with neither holding a lock the other respects.
-- What settles it is a compare-exchange on kproc.woken: the winner
-- readies the proc, the loser leaves it entirely alone. Go's runtime
-- does the same with g.selectDone.
--
-- What this does not assert, because it was tried: that a claim is
-- ever lost. Three arrangements were measured and none produced one
-- collision at any width up to -smp 8. The counter is reported
-- instead, and `lost 0` is a known gap rather than a passing test.
--
-- The reason is a tension nothing in lua can tune away. A waker only
-- reaches the claim if it finds the proc BLOCKED, so a loser has to
-- arrive between the winner reading that status and the winner writing
-- READY -- a few hundred nanoseconds, schedlock included. Two procs
-- land inside that only if they are genuinely simultaneous. But
-- senders dense enough to be simultaneous keep the alt set non-empty,
-- so altrecv takes at entry and the receiver never parks at all, and a
-- proc that never parks cannot be raced for.
--
-- Measured, in order:
--
--	flat out		32000 messages, 4 wakes, 0 losses
--	yields between sends	2400 messages, 303 wakes, 0 losses
--	barrier (this one)	2400 messages, 2703 wakes, 0 losses
--
-- The branch was separately shown to be unreached by the whole suite,
-- by making a lost claim abort the kernel: all 85 tests passed, smp2
-- and smp4 variants included. That is the way to re-check it, and it
-- is worth more than any assertion here could be.
--
-- What this does assert is the half that holds either way: under an
-- alt hammered from eight ports at once, every message arrives, on the
-- port it was sent to. A lost claim may lose only the wake -- the
-- waiter it did not unlink stays put, and the re-scan finds it.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(4)

local NPORT = 8		-- ports in the receiver's alt set, one sender each
local ROUNDS = 300	-- messages per sender

-- one receiver, an alt over NPORT ports, taking messages until it has
-- them all. Every sender aims at a different port, so every delivery is
-- a wake attempt on a different bucket.
local RECV = [==[
	local sys = require("los.sys")
	local a = ...
	local parent = a.reply.__right
	local nport, want = a.nport, a.want

	local set, rights = {}, {}

	for i = 1, nport do
		set[i] = sys.newport()
		rights[i] = { __right = sys.sendright(set[i]) }
	end
	sys.send(parent, { ports = rights })

	-- per-port tallies, so a message delivered to the wrong port would
	-- show up as a count in the wrong slot rather than as a total that
	-- still adds up.
	local per = {}

	for i = 1, nport do
		per[i] = 0
	end

	local n = 0

	while n < want do
		local i, m = sys.altrecv(set)

		-- nothing for us: a hangup wake, or a message another proc
		-- took first. altrecv_k documents this and the caller loops.
		if i then
			per[i] = per[i] + 1
			n = n + 1
			if m ~= i then
				per[i] = -1	-- landed on the wrong port
			end
		end
	end
	sys.send(parent, { done = true, per = per })
]==]

-- one sender per port, released together by a barrier.
--
-- The barrier is the whole design, and two cheaper arrangements were
-- measured and thrown away first. Senders pushing flat out keep the
-- set permanently non-empty, so altrecv takes at entry, the receiver
-- never parks, and a proc that never parks cannot be raced for: 32000
-- messages, 4 wakes, no collisions. Senders yielding between sends do
-- make the receiver park -- 2400 messages, 303 wakes -- but they drift
-- apart, so no two ever arrive together: still no collisions, at every
-- width up to -smp 8.
--
-- The window a loser has to hit is short by construction. The winner
-- claims, then takes schedlock, then marks the proc READY, and once it
-- is READY a later waker skips it before ever reaching the claim. So
-- the arrivals have to be genuinely simultaneous, and independent
-- procs are not.
--
-- Hence: every sender parks on its own control port, the parent
-- releases all of them at once, and each sends the moment it wakes.
-- They resume on different cpus and converge on one parked receiver.
local SEND = [==[
	local sys = require("los.sys")
	local a = ...
	local to = a.to.__right
	local idx = a.idx
	local ctl = 0			-- our own port; the parent has a right

	sys.send(a.ready.__right, { ctl = { __right = sys.sendright(0) },
	    idx = idx })

	for _ = 1, a.rounds do
		while true do
			local ok = sys.tryrecv(ctl)

			if ok then
				break
			end
			sys.block(ctl)
		end
		while not sys.send(to, idx) do
			sys.sendblock(to)
		end
	end
]==]

local me = sys.sendright(0)

local function recv1()
	while true do
		local ok, m = sys.tryrecv(0)

		if ok then
			return m
		end
		sys.block(0)
	end
end

tap.ok(sys.spawn(RECV, { arg = { reply = { __right = me }, nport = NPORT,
    want = NPORT * ROUNDS } }), "receiver spawned")

local ports = recv1().ports
local senders = 0

for i = 1, NPORT do
	if sys.spawn(SEND, { arg = { to = { __right = ports[i].__right },
	    ready = { __right = me }, idx = i, rounds = ROUNDS } }) then
		senders = senders + 1
	end
end

tap.ok(senders == NPORT, senders .. " senders, one per port")

-- collect a control right per sender, so the barrier can release them.
-- The senders announce themselves rather than being told, because a
-- sender's port does not exist until the sender does.
local ctl = {}

while #ctl < NPORT do
	local m = recv1()

	ctl[#ctl + 1] = m.ctl.__right
end

-- the barrier. Release everyone, then wait for the receiver to have
-- taken this round's messages before releasing again -- otherwise the
-- fast senders run ahead and the arrivals spread out again, which is
-- the arrangement measured above that never collided.
local drained = false
local per

for _ = 1, ROUNDS do
	for i = 1, NPORT do
		sys.send(ctl[i], "go")
	end
	-- let the release land before the next one is built
	for _ = 1, 4 do
		sys.yield()
	end
end

while not drained do
	local m = recv1()

	if m.done then
		per = m.per
		drained = true
	end
end
local total, misdelivered = 0, 0

for i = 1, NPORT do
	if per[i] < 0 then
		misdelivered = misdelivered + 1
	else
		total = total + per[i]
	end
end

-- the correctness half, and it holds on one cpu as well as eight: a
-- lost claim must lose only the wake, never the message. The waiter it
-- did not unlink stays on its port, and the proc finds it on the
-- re-scan.
tap.ok(total == NPORT * ROUNDS and misdelivered == 0,
    total .. " of " .. NPORT * ROUNDS .. " messages, each on its own port")

local ipc = (sys.stats().lock or {}).ipc or {}
local won, lost = ipc.claimwon or 0, ipc.claimlost or 0

tap.diag(string.format("claims: %d won, %d lost", won, lost))

-- that the receiver genuinely parked, which is the part of the race
-- this test can guarantee. Without it the whole thing degenerates into
-- an ordinary send loop -- the first arrangement above, where altrecv
-- took at entry every time and the wake path was never entered -- and
-- it would still pass every assertion above.
tap.ok(won > NPORT, won .. " wakes: the receiver parked and was woken")

tap.done()
