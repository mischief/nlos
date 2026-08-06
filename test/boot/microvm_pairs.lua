-- N independent pairs of procs, each pair passing a message back and
-- forth between themselves and nobody else.
--
-- This is the companion to microvm_spin.lua, and it asks the one
-- question that test cannot: spinners scale because they share
-- nothing, so they say that lua runs in parallel and nothing about the
-- kernel. Every round trip here takes the ipc lock four times -- two
-- sends, two wakeups -- over ports no other pair touches. There is no
-- shared server proc and no shared queue, so if the pairs do not speed
-- up with more cpus, the lock is the reason and nothing else can be.
--
-- The parent brokers the introductions and then stays out of it. Two
-- procs cannot be given rights to each other at spawn, because neither
-- port exists until its proc does, so each child sends the parent a
-- send right to itself and the parent hands each one its peer's.
--
-- Like the spinner, this asserts almost nothing. The measurement is the
-- wall clock of the whole boot taken by the host at one cpu against
-- two and four, with a trivial payload's boot time subtracted. See
-- AGENTS.md: "Prefer an honest external measurement over an assertion
-- that cannot fail."

local sys = require("los.sys")
local tap = require("tap")

tap.plan(3)

local NPAIR = 4
local ROUNDS = 200000

-- the body both sides run. The two differ only in who sends first,
-- which is what keeps a pair from deadlocking on the first round.
local CHILD = [==[
	local sys = require("los.sys")
	local a = ...
	local parent = a.reply.__right
	local rounds = a.rounds
	local first = a.first

	local function recv1()
		while true do
			local ok, m = sys.tryrecv(0)

			if ok then
				return m
			end
			sys.block(0)
		end
	end

	-- a send right to our own port, which is the only way the peer
	-- can ever name us.
	sys.send(parent, { pair = a.pair, port = { __right = sys.sendright(0) } })

	local peer = recv1().peer.__right

	if first then
		for _ = 1, rounds do
			sys.send(peer, "p")
			recv1()
		end
	else
		for _ = 1, rounds do
			recv1()
			sys.send(peer, "q")
		end
	end

	-- home is read at the end, while this proc is still alive:
	-- counting sys.procs() afterwards sees only the survivors.
	sys.send(parent, { done = true, home = sys.pidstat().home })
]==]

local me = sys.sendright(0)
local spawned = 0

for i = 1, NPAIR do
	for _, first in ipairs({ true, false }) do
		if sys.spawn(CHILD, { arg = { reply = { __right = me },
		    rounds = ROUNDS, pair = i, first = first } }) then
			spawned = spawned + 1
		end
	end
end

tap.ok(spawned == NPAIR * 2, spawned .. " procs, " .. NPAIR .. " pairs")

local function recv1()
	while true do
		local ok, m = sys.tryrecv(0)

		if ok then
			return m
		end
		sys.block(0)
	end
end

-- the introductions. Both halves of a pair are collected before either
-- is answered, because a right to the peer is what the answer carries.
local waiting = {}
local introduced = 0

while introduced < NPAIR do
	local m = recv1()
	local other = waiting[m.pair]

	if other then
		waiting[m.pair] = nil
		sys.send(m.port.__right, { peer = { __right = other } })
		sys.send(other, { peer = { __right = m.port.__right } })
		introduced = introduced + 1
	else
		waiting[m.pair] = m.port.__right
	end
end

tap.ok(introduced == NPAIR, "every pair knows its peer")

local done = 0
local homes = {}

while done < NPAIR * 2 do
	local m = recv1()

	if m.done then
		done = done + 1
		local h = tonumber(m.home) or 0

		homes[h] = (homes[h] or 0) + 1
	end
end

tap.ok(done == NPAIR * 2, "every proc finished its rounds")
tap.diag(NPAIR * ROUNDS .. " round trips over " .. NPAIR .. " port pairs")

local parts = {}

for cpu, n in pairs(homes) do
	parts[#parts + 1] = string.format("cpu%d=%d", cpu, n)
end
table.sort(parts)
tap.diag("procs by home: " .. table.concat(parts, " "))

tap.done()
