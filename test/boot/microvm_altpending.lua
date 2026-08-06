-- an alt woken on one port must still find the message on another.
--
-- This is the case the wake protocol split in two, and the one a reader
-- is most likely to get wrong. A proc parked in alt over ports A and B
-- has a waiter on each. A sender on A wakes it -- and unlinks the entry
-- on A only, because a waker holds one port's bucket and B's list is
-- not under it. B's entry is left behind for the woken proc to collect
-- itself, in wait_reap.
--
-- So a message that arrived on B while the proc was parked has nothing
-- pointing at it by the time the proc runs. The only thing that finds
-- it is the re-scan of the whole set on resume. Take that away and the
-- message sits in B's queue until something else happens to wake the
-- proc, which in a real server is until the next request -- a stall
-- that looks like a slow peer and not like a bug.
--
-- No race and no second cpu: the child is parked before either send,
-- and both sends land while it is parked. It fails as a hang rather
-- than as a wrong answer, so the harness timeout is the assertion of
-- last resort and tap.plan is the one that reports it properly.
--
-- Deliberately not written with los.thread. That library parks threads
-- on its own and would put its scheduler between this test and the
-- kernel call being tested.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(4)

local NPORT = 3

-- the child makes its own ports and hands back a send right to each, so
-- the parent can aim at one specific member of the alt set.
local CHILD = [==[
	local sys = require("los.sys")
	local a = ...
	local parent = a.reply.__right
	local nport = a.nport

	local ports, set = {}, {}

	for i = 1, nport do
		ports[i] = sys.newport()
		set[i] = ports[i]
	end

	local rights = {}

	for i = 1, nport do
		rights[i] = { __right = sys.sendright(ports[i]) }
	end
	sys.send(parent, { ports = rights })

	-- take everything the set has, one alt at a time, and report each
	-- message with the index that delivered it. The parent knows which
	-- port it sent to, so it can tell a message found by the wake from
	-- one found by the re-scan.
	--
	-- The loop is the contract, not defensive coding: sys.altrecv may
	-- return nothing, and altrecv_k's comment says so -- a hangup wake
	-- or another proc taking the message first. This test provokes one
	-- of those on the first call every time. The parent receiving the
	-- introduction message disposes of the two rights it carried,
	-- which unrefs both of these ports, and a dropped reference wakes
	-- every receiver so it can re-check sys.hungup.
	local got = {}

	while #got < nport do
		local i, m = sys.altrecv(set)

		if i then
			got[#got + 1] = { i = i, m = m }
		end
	end
	sys.send(parent, { got = got })
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

tap.ok(sys.spawn(CHILD, { arg = { reply = { __right = me }, nport = NPORT } }),
    "child spawned")

local ports = recv1().ports

tap.ok(#ports == NPORT, NPORT .. " ports in the alt set")

-- let the child reach altrecv and park. sys.yield does not promise the
-- child ran, so this loops: the child is parked once it has stopped
-- being runnable, and the cheapest honest way to wait for that here is
-- to give the scheduler several laps.
for _ = 1, 200 do
	sys.yield()
end

-- port 3 first, then port 1. Port 1's send is the one that wakes the
-- child -- port 3's lands on a proc that is already parked and whose
-- waiter on 3 is not the one being unlinked.
--
-- Order matters: 3 has to be queued before the wake, or this tests
-- nothing but two ordinary deliveries.
sys.send(ports[3].__right, "three")
sys.send(ports[1].__right, "one")
sys.send(ports[2].__right, "two")

local got = recv1().got
local seen = {}

for _, g in ipairs(got) do
	seen[g.m] = g.i
end

tap.ok(#got == NPORT, "the child received all " .. NPORT .. " messages")

-- the message queued before the wake is the whole point. Naming it
-- rather than counting, so a test that passes by delivering three
-- copies of the same thing cannot.
tap.ok(seen.three == 3 and seen.one == 1 and seen.two == 2,
    "the message queued before the wake was found, on its own port")

tap.done()
