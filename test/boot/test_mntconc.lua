-- a mount touched by several threads at once, from cold.
--
-- Two things meet here, and the second was hidden behind the first.
--
-- A mount opens its session on first use, and establishing one is a
-- round trip: it parks. So every thread arriving while the first is
-- waiting also found no session and opened one of its own, each with a
-- fid space of its own -- the last assignment winning and every fid the
-- others minted naming nothing. That does not heal, because ns caches
-- the root handle it walked from: a mount used concurrently the first
-- time stayed broken afterwards even for a single serial reader.
--
-- Underneath it, the server hands out fids from a counter, and with
-- opts.workers each request is dispatched in its own thread. Read, add,
-- store: cut between any two and two clients hold the same fid, so a
-- clunk from one takes the other's handle away.
--
-- The server is tortured rather than this payload, since the race being
-- asked about is between ITS workers; sys.set_torture takes a pid so a
-- test can point it somewhere other than itself. Every file's contents
-- name it, so a crossed fid is a mismatch rather than a guess, and the
-- readers go straight at a cold mount with no warm-up read first --
-- warming it hides the session race completely.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local ns = require("ns")
local mnt = require("mnt")
local dev = require("dev")

tap.plan(5)

local NFILE, ROUNDS = 6, 8

local SERVER = [[
local dev = require("dev")
local srv = require("srv")

srv.main(function()
	local t = {}

	for i = 1, ]] .. NFILE .. [[ do
		t["f" .. i] = "contents of f" .. i .. "\n"
	end
	return dev.mem(t)
end, { workers = 8 })
]]

local pid, h = sys.spawn(SERVER, { name = "concsrv" })

tap.ok(pid and h, "spawned a server serving from a worker window")
tap.ok(sys.set_torture(pid, true), "and its workers are cut everywhere")

local N = ns.new()

N:mount("/", dev.mem({ ["init.lua"] = "-- local\n" }), "mem",
    { tree = { ["init.lua"] = "-- local\n" } })
tap.ok(N:mount("/w", mnt.new(h), "mnt", { port = { __right = h } }),
    "mounted it, and nothing has read through it yet")

-- one reader per file, each only ever asking for its own. Results go in
-- per-thread slots: a shared tally would be the read-modify-write the
-- server side of this is about.
local wrong, rounds = {}, {}

for i = 1, NFILE do
	thread.spawn(function()
		local want = "contents of f" .. i .. "\n"
		local bad, n = 0, 0

		for _ = 1, ROUNDS do
			local ok, got = pcall(N.readfile, N, "/w/f" .. i)

			if not ok or got ~= want then
				bad = bad + 1
			end
			n = n + 1
		end
		wrong[i], rounds[i] = bad, n
	end)
end

thread.run()

local bad, did = 0, 0

for i = 1, NFILE do
	bad = bad + (wrong[i] or 0)
	did = did + (rounds[i] or 0)
end

tap.is(did, NFILE * ROUNDS, "every reader finished its rounds")
tap.is(bad, 0, "and every read got its own file, first one included")

sys.set_torture(pid, false)
tap.done()
