-- what a cross-proc round trip costs, as a distribution rather than a
-- mean, sweeping the work the server does per request.
--
-- The same measurement as test/boot/microvm_rtdist.lua, so the two
-- platforms can be read side by side. That comparison is the point:
-- every filesystem operation on this board is bimodal, and under
-- microvm the identical bench is flat even when the server runs for
-- seven quanta. Whatever the second mode is, it is not the scheduler.
--
-- Times are microseconds. Read the p90 column against p50: a fixed
-- offset is a period the reply waits for, a proportional one is the
-- server's own slice.
local sys = require("los.sys")

local CPMS = sys.stats().cycles_per_ms
local N = tonumber(arg and arg[1]) or 100

local me = sys.self()
local rp = sys.newport("rtdist_reply")
local myright = sys.sendright(rp)

-- the reply right comes once, at setup, and every reply goes back down
-- it. A right in each request would be a right per message to close.
local server = [[
	local a = ...
	local sys = require("los.sys")
	local p = sys.newport("rtdist_srv")
	local back = a.reply.__right

	sys.send(back, { port = { __right = sys.sendright(p) } })
	while true do
		local _, m = sys.alt({ { port = p } })

		if type(m) ~= "table" then break end
		local x = 0

		for i = 1, m.spin do x = x + i end
		sys.send(back, { x = x })
	end
]]

local pid = sys.spawn(server, { arg = { reply = { __right = myright } } })

if not pid then
	print("rtdist: cannot spawn the server")
	return
end

local _, hello = sys.alt({ { port = rp } })
local sright = type(hello) == "table" and hello.port and hello.port.__right

if not sright then
	print("rtdist: the server sent no port")
	return
end

local function quantiles(t)
	table.sort(t)
	local function q(f)
		return t[math.max(1, math.floor(#t * f))] * 1000 // CPMS
	end
	return q(0.0), q(0.25), q(0.5), q(0.9), q(0.99), t[#t] * 1000 // CPMS
end

-- the control: the same send and take, in one proc, so no proc is
-- blocked and no proc is woken. What is left is the message machinery
-- alone, and the difference from the spin-0 row below is scheduling.
do
	local p = sys.newport("rtdist_self")
	local t0 = sys.ticks()

	for _ = 1, N do
		sys.send(p, { spin = 0 })
		sys.tryrecv(p)
	end
	print(string.format("same-proc send+take: %d us",
	    (sys.ticks() - t0) * 1000 // CPMS // N))

	-- the same again through alt, on a port that already holds the
	-- message. Same call the round trip makes, same wait-set build, and
	-- it never blocks -- so what a round trip costs above this is
	-- blocking and being woken, and nothing else.
	t0 = sys.ticks()
	for _ = 1, N do
		sys.send(p, { spin = 0 })
		sys.alt({ { port = p } })
	end
	print(string.format("same-proc alt:         %d us",
	    (sys.ticks() - t0) * 1000 // CPMS // N))
	sys.close(p)
end

print(string.format("%8s %8s %8s %8s %8s %8s %8s %8s %7s",
    "spin", "min", "p25", "p50", "p90", "p99", "max", "laps", "inlua"))

for _, spin in ipairs({ 0, 100, 1000, 10000, 100000 }) do
	local samples = {}
	local l0 = sys.stats().laps
	local c0 = sys.pidstat(me).cputime
	local s0 = sys.pidstat(pid).cputime

	for _ = 1, N do
		local t0 = sys.ticks()

		sys.send(sright, { spin = spin })
		sys.alt({ { port = rp } })
		samples[#samples + 1] = sys.ticks() - t0
	end

	local laps = (sys.stats().laps - l0) // N
	local mn, p25, p50, p90, p99, mx = quantiles(samples)
	-- what share of the wall clock either proc was running. The rest
	-- is the kernel's own work plus anything that took the cpu away
	-- from lua-os altogether, and on a board where the whole os is
	-- one freertos task at priority 1 that second part is real.
	local wall = 0

	for _, v in ipairs(samples) do wall = wall + v end

	local cpu = (sys.pidstat(me).cputime - c0) +
	    (sys.pidstat(pid).cputime - s0)

	print(string.format("%8d %8d %8d %8d %8d %8d %8d %8d %6d%%",
	    spin, mn, p25, p50, p90, p99, mx, laps,
	    wall > 0 and (cpu * 100 // wall) or 0))
end

-- the second control: a yield and a resume, with no message at all.
-- Between this and the same-proc number, a round trip has nowhere left
-- to hide -- it is machinery, or it is being put down and picked up.
--
-- Last, not before the sweep: a run of bare yields ahead of it leaves
-- the round trips below stalled, which is worth a look of its own.
do
	local t0 = sys.ticks()

	for _ = 1, N do sys.yield() end
	print(string.format("bare yield+resume:  %d us",
	    (sys.ticks() - t0) * 1000 // CPMS // N))
end

sys.send(sright, "quit")
sys.close(sright)
sys.close(myright)
sys.close(rp)
