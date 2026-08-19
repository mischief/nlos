-- the distribution of a cross-proc round trip, not its average.
--
-- On the T-Deck every filesystem operation is bimodal: a stat is 5ms or
-- 10, a read is 10ms or 21, and the slow mode costs about as much again
-- as the operation itself. An average hides that completely -- the two
-- modes average to a number neither of them ever takes.
--
-- So this reports quantiles, and it sweeps the amount of work the
-- server does per request. If the penalty tracks the server's own cost
-- rather than sitting at some fixed period, the gap is a scheduling
-- boundary the reply has to wait for, and the sweep says so directly.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

local CPMS = sys.stats().cycles_per_ms
local N = 200

local rp = sys.newport("rtdist_reply")
local myright = sys.sendright(rp)

-- the server: recv, burn `spin` iterations, reply. The burn is a plain
-- lua loop so it costs reductions as well as time, which is what makes
-- it able to cross a quantum.
local server = [[
	local a = ...
	local sys = require("los.sys")
	local p = sys.newport("rtdist_srv")

	-- the reply right comes once, at setup, and every reply goes back
	-- down it. A right in each request would be a right per message to
	-- close, and 512 of them is the whole table.
	local back = a.reply.__right

	sys.send(back, { port = { __right = sys.sendright(p) } })
	while true do
		local _, m = sys.alt({ p })

		if type(m) ~= "table" then break end
		local x = 0

		for i = 1, m.spin do x = x + i end
		sys.send(back, { x = x })
	end
]]

local pid = sys.spawn(server, { arg = { reply = { __right = myright } } })

if not tap.ok(pid, "server spawned") then
	tap.done()
	return
end

local hello = thread.recvtimeout(rp, 5000)
local sright = type(hello) == "table" and hello.port and hello.port.__right

if not tap.ok(sright, "server sent its port") then
	tap.done()
	return
end

local function quantiles(t)
	table.sort(t)
	local function q(f)
		return t[math.max(1, math.floor(#t * f))] * 1000 // CPMS
	end
	return q(0.0), q(0.25), q(0.5), q(0.9), q(0.99), t[#t] * 1000 // CPMS
end

-- the controls, in microseconds: the same send and take with no proc
-- blocked and none woken, and a yield with no message at all. What a
-- round trip costs above the two of them is being put down and picked
-- up again.
do
	local p = sys.newport("rtdist_self")
	local t0 = sys.ticks()

	for _ = 1, N do
		sys.send(p, { spin = 0 })
		sys.tryrecv(p)
	end
	tap.diag(string.format("same-proc send+take: %d ns",
	    (sys.ticks() - t0) * 1000000 // CPMS // N))
	sys.close(p)

	t0 = sys.ticks()
	for _ = 1, N do sys.yield() end
	tap.diag(string.format("bare yield+resume:  %d ns",
	    (sys.ticks() - t0) * 1000000 // CPMS // N))
end

-- one line per spin size, in microseconds. What to read: if p90 grows
-- as a fixed offset above p50 the boundary is a period, and if it grows
-- in proportion it is the server's own slice.
tap.diag(string.format("%8s %7s %7s %7s %7s %7s %7s",
    "spin", "min", "p25", "p50", "p90", "p99", "max"))

for _, spin in ipairs({ 0, 100, 1000, 10000, 100000 }) do
	local samples = {}

	for _ = 1, N do
		local t0 = sys.ticks()

		sys.send(sright, { spin = spin })
		sys.alt({ rp })
		samples[#samples + 1] = sys.ticks() - t0
	end

	local mn, p25, p50, p90, p99, mx = quantiles(samples)

	tap.diag(string.format("%8d %7d %7d %7d %7d %7d %7d",
	    spin, mn, p25, p50, p90, p99, mx))
end

tap.ok(true, "swept")
tap.done()
