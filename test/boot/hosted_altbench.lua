-- what 64 reads at once cost against 64 in a row, over a port.
--
-- microvm_p9bench's two phases with a lua file server in place of
-- virtio, so what is measured is the thread scheduler's park and wake
-- rather than a transport. This platform is the one a profiler sees
-- into.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local thread = require("los.thread")
local tap = require("tap")

local NBLOCK = 64

tap.plan(3)

local SERVER = [[
local devtree = require("devtree")
local srv = require("srv")

srv.main(function()
	local files = {}

	for i = 0, 63 do
		files["b" .. i] = ("%04d"):format(i):rep(16)
	end
	return devtree.mem(files)
end)
]]

local pid, h = sys.spawn(SERVER, { name = "blockserver" })

tap.ok(pid and h, "spawned a file server")

local N = ns.new()

N:mount("/blocks", mnt.new(h), "mnt", { port = { __right = h } })

-- opened outside the timed region, so what is timed is round trips
local handles = {}

for i = 0, NBLOCK - 1 do
	handles[i] = N:open("/blocks/b" .. i, "r")
end

local CYCMS = sys.stats().cycles_per_ms
local ROUNDS = 20

-- ticks, not uptime_ms: one phase is well under a millisecond here
local function micros(cyc)
	return cyc / (CYCMS / 1000)
end

local t0 = sys.ticks()

for _ = 1, ROUNDS do
	for i = 0, NBLOCK - 1 do
		handles[i]:seek(0)
		handles[i]:read(64)
	end
end

local seq = (sys.ticks() - t0) / ROUNDS

t0 = sys.ticks()

local left = NBLOCK * ROUNDS

for _ = 1, ROUNDS do
	for i = 0, NBLOCK - 1 do
		thread.spawn(function()
			handles[i]:seek(0)
			handles[i]:read(64)
			left = left - 1
		end)
	end
	thread.run()
end

local par = (sys.ticks() - t0) / ROUNDS

tap.ok(left == 0, "every concurrent read finished")
tap.diag(("sequential: %d in %.0f us"):format(NBLOCK, micros(seq)))
tap.diag(("concurrent: %d in %.0f us"):format(NBLOCK, micros(par)))
tap.diag(("concurrent/sequential: %.2fx"):format(par / seq))
-- a loose bound: what this catches is a scheduler that turns
-- concurrency into a per-case walk, which reads as several times the
-- sequential cost rather than a few tens of percent.
tap.ok(par / seq < 3, ("64 at once is not several times 64 in a row (%.2fx)"):format(par / seq))

for i = 0, NBLOCK - 1 do
	handles[i]:close()
end
sys.close(h)
tap.done()
