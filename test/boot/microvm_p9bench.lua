-- what a 9p round trip costs, and what 64 of them at once cost.
--
-- the baseline a pipelined transport has to beat. Today the transport
-- is one request in flight (virtio_9p.c's p9_inflight and its single
-- static buffer pair), lib/p9fs.lua sends every message under the same
-- constant tag, and lib/srv.lua dispatches one message at a time -- so
-- fanning reads out cannot make them finish sooner. This test does not
-- assert that it does. It measures the gap.
--
-- Both phases read the same 64 blocks and do exactly one Tread each:
-- the handles are opened outside the timed region, so what is timed is
-- round trips and nothing else. Without that the concurrent phase would
-- also be paying a walk, an open and a clunk per block, and the
-- comparison would be against a different amount of work.
--
-- Each block carries its own index, so a reply handed to the wrong
-- waiter shows up as data rather than as a hang -- the property that
-- has to survive tags being allocated per request.
--
-- The scheduler-lap counts are the sizing number. p9.rpc yields between
-- polls rather than spinning (drivers.c's p9_rpc_k), so laps per round
-- trip says how much of the latency is the guest waiting rather than
-- working, and that is exactly the latency a second outstanding request
-- could hide.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
-- los.thread, not "thread": lib/*.lua all require it under that name,
-- and a second copy loaded under another name is a second scheduler
-- with its own _current. mnt.lua's inthread() would then say no and
-- call sys.block from inside a coroutine, which blocks the proc in the
-- kernel while its thread scheduler carries on running.
local thread = require("los.thread")
local tap = require("tap")

local NBLOCK = 64
local BLOCKSZ = 4096

tap.plan(8)

local caps = sys.granted()

if not tap.ok(caps.p9 ~= nil, "a p9 capability was granted") then
	tap.diag("no virtio-9p device found; the rest cannot run")
	tap.done()
	return
end

local N = ns.new()
local mok, merr = N:mount("/host", mnt.new(caps.p9), "mnt",
    { port = { __right = caps.p9 } })

if not tap.ok(mok, "mounted virtio-9p at /host") then
	tap.diag("mount failed: " .. tostring(merr))
	tap.done()
	return
end

-- ---- a spinner, to count what the machine did while we waited ----
--
-- the device microvm_p9mount.lua uses to prove 9p io does not stall the
-- machine, read here for its rate rather than for being nonzero: a proc
-- that yields in a loop takes one turn per scheduler lap, so the delta
-- across a timed region is laps.

local counter = sys.newport()

sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local n = 0

	while true do
		n = n + 1
		sys.send(a.__right, n)
		sys.yield()
	end
]], { arg = { __right = sys.sendright(counter) } })

local function laps()
	local last = 0

	while true do
		local ok, v = sys.tryrecv(counter)

		if not ok then
			return last
		end
		last = v
	end
end

-- sys.ticks() rather than uptime_ms: a whole phase here is ~20ms, so
-- millisecond granularity cannot resolve one round trip at all -- the
-- port floor below measures as a flat zero in ms. sys.stats() carries
-- the tsc calibration so the cycles can still be reported in real
-- units.
local CYCMS = sys.stats().cycles_per_ms

local function measure(fn)
	sys.yield()

	local l0 = laps()
	local t0 = sys.ticks()

	fn()

	local t1 = sys.ticks()
	local l1 = laps()

	return t1 - t0, l1 - l0
end

local function report(what, cyc, lp)
	tap.diag(string.format(
	    "%s: %d in %.1f ms (%.1f us each), %d laps (%.2f each)",
	    what, NBLOCK, cyc / CYCMS, (cyc / NBLOCK) * 1000 / CYCMS,
	    lp, lp / NBLOCK))
end

-- ---- the floor: a bare port round trip, no filesystem at all ----
--
-- what any mounted read costs before 9p is involved, since lib/mnt.lua
-- is a request to another proc and a reply on a port either way. Read
-- against the numbers below it: whatever share of a 9p read this
-- accounts for is cost that pipelining the wire cannot remove, because
-- it is not on the wire.

local echoin = sys.newport()
local echoout = sys.newport()
local toecho = sys.sendright(echoin)

sys.spawn([[
	local sys = require("los.sys")
	local a = ...

	while true do
		sys.block(a.__in.__right)
		local ok, m = sys.tryrecv(a.__in.__right)

		if ok then
			sys.send(a.__out.__right, m)
		end
	end
]], { arg = { __in = { __right = echoin }, __out = { __right = sys.sendright(echoout) } } })

local pingcyc, pinglaps = measure(function()
	for i = 1, NBLOCK do
		sys.send(toecho, i)
		sys.block(echoout)
		sys.tryrecv(echoout)
	end
end)

tap.ok(true, NBLOCK .. " bare port round trips")
report("port floor", pingcyc, pinglaps)

-- ---- and the same round trip carrying a real payload ----
--
-- the floor above sends an integer, which is not what a read costs: a
-- 4K reply is serialized into a growing buffer, copied through the
-- kernel and rebuilt as a lua string on the far side.
--
-- Repeated because the interesting failure is not the absolute number
-- but its drift. src/platform/microvm/pmm.c is first-fit over a hole
-- list, and when that list did not coalesce, serialize()'s doubling
-- left a hole of every size it passed through -- so the list grew
-- without bound and the same round trip got slower forever: 116us on
-- the first hundred, 184us four hundred later, recovered only by a
-- reboot. Flatness across rounds is the property; the ratio is checked
-- rather than the microseconds, which are machine-specific.

local DRIFT_ROUNDS = 12
local DRIFT_MAX = 1.5
local payload = { data = string.rep("x", BLOCKSZ), n = BLOCKSZ }
local first, last

for r = 1, DRIFT_ROUNDS do
	local cyc = measure(function()
		for _ = 1, NBLOCK do
			sys.send(toecho, payload)
			sys.block(echoout)
			sys.tryrecv(echoout)
		end
	end)

	tap.diag(string.format("  %dB payload, round %d: %.2f us each",
	    BLOCKSZ, r, (cyc / NBLOCK) * 1000 / CYCMS))
	first = first or cyc
	last = cyc
end

tap.ok(last < first * DRIFT_MAX, string.format(
    "port round trips do not slow down under churn (round %d is %.2fx round 1, limit %.1fx)",
    DRIFT_ROUNDS, last / first, DRIFT_MAX))

local function blockmark(i)
	return string.format("block %04d\n", i)
end

-- every block must be the one that was asked for
local function checkblocks(got)
	for i = 0, NBLOCK - 1 do
		local d = got[i]

		if type(d) ~= "string" or #d ~= BLOCKSZ then
			return false, string.format("block %d: %s bytes", i,
			    d and tostring(#d) or "no")
		end
		if d:sub(1, #blockmark(i)) ~= blockmark(i) then
			return false, string.format("block %d starts %q", i,
			    d:sub(1, 12))
		end
	end
	return true
end

-- one handle per block, all opened before either phase is timed. Each
-- is its own fid (lib/p9fs.lua clones one per open), which is what lets
-- 64 threads read without sharing a position.
local handles = {}

for i = 0, NBLOCK - 1 do
	local f, err = N:open("/host/blocks.bin", "r")

	if not f then
		tap.ok(false, "open blocks.bin: " .. tostring(err))
		tap.done()
		return
	end
	handles[i] = f
end

tap.ok(true, string.format("opened %d handles on /host/blocks.bin", NBLOCK))

-- ---- one at a time ----

local seq = {}
local seqcyc, seqlaps = measure(function()
	for i = 0, NBLOCK - 1 do
		handles[i]:seek("set", i * BLOCKSZ)
		seq[i] = handles[i]:read(BLOCKSZ)
	end
end)

local sok, serr = checkblocks(seq)

if not tap.ok(sok, NBLOCK .. " sequential block reads") then
	tap.diag(tostring(serr))
	tap.done()
	return
end
report("sequential", seqcyc, seqlaps)

-- ---- all at once, one thread each ----
--
-- the shape a scatter/gather read wants. lib/mnt.lua already supports
-- it: each thread gets its own reply port (thread.replyport), so there
-- is no tag and no demultiplexer to serialize on. Everything below mnt
-- is where it collapses today.

local par = {}
local parcyc, parlaps = measure(function()
	for i = 0, NBLOCK - 1 do
		thread.spawn(function()
			handles[i]:seek("set", i * BLOCKSZ)
			par[i] = handles[i]:read(BLOCKSZ)
		end)
	end
	thread.run()
end)

local pok, perr = checkblocks(par)

if not tap.ok(pok, NBLOCK .. " concurrent block reads, one thread each") then
	tap.diag(tostring(perr))
end
report("concurrent", parcyc, parlaps)
tap.diag(string.format("concurrent/sequential: %.2fx", parcyc / seqcyc))

for i = 0, NBLOCK - 1 do
	handles[i]:close()
end

-- the property the window bought, and the one worth defending: the
-- same reads issued together finish sooner than issued in a row.
--
-- Stated as "not slower" rather than as a speedup figure. What is
-- available to win here is the device latency a second request can
-- overlap, and on a local virtio-9p device serving a host directory
-- that is small -- most of a read is guest-side work that stays serial
-- however deep the window is. A ratio tuned to today's margin would be
-- a machine-speed assertion wearing a correctness costume.
tap.ok(parcyc <= seqcyc, string.format(
    "64 reads at once beat 64 in a row (%.2fx)", parcyc / seqcyc))

tap.done()
