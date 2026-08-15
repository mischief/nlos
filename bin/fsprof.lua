-- Where a filesystem call's time goes inside fatsrv, by line.
--
--	fsprof [readdir|read] PATH [rounds] [ring]
--
-- The server is traced, not this program: what is wanted is the work
-- under the reply, and a client sees only the round trip.

-- Arming a trace costs the traced proc about 4.7x, so read the shares
-- rather than the absolute numbers. A count is a separate question from
-- a cost -- something cheap running very often looks like neither until
-- both columns are in front of you.
local sys = require("los.sys")
local ps = require("ps")
local prog = require("prog")
local unistd = require("posix.unistd")

local N = assert(prog.ns(), "fsprof: no namespace")
local verb = (arg and arg[1]) or "readdir"
local path = (arg and arg[2]) or "/lib"
local rounds = tonumber(arg and arg[3]) or 5
local ring = tonumber(arg and arg[4]) or 20000

if verb ~= "readdir" and verb ~= "read" then
	print("usage: fsprof [readdir|read] PATH [rounds] [ring]")
	return
end

local who
for _, pid in ipairs(sys.procs()) do
	if sys.name(pid) == "fatsrv" then who = pid end
end

if not who then
	print("fsprof: no fatsrv")
	return
end

local armed, aerr = pcall(sys.set_trace, who, ring)

if not armed then
	print("fsprof: cannot trace pid " .. who .. ": " .. tostring(aerr))
	return
end

for _ = 1, rounds do
	if verb == "read" then
		assert(N:readfile(path))
	else
		assert(N:readdir(path))
	end
end

-- read the ring before disarming: turning the trace off frees it
local ok, out = pcall(ps.tracehist, who, 12)
local h = sys.tracehist(who)

pcall(sys.set_trace, who, 0)
unistd.write(1, (ok and out or tostring(out)) .. "\n")

-- and by count, which is a different question: the top of the cost
-- list held barely a thousand line events out of a ring of hundreds of
-- thousands, so something cheap is running very often.
local n, cyc = 0, sys.stats().cycles_per_ms

for _, r in ipairs(h) do n = n + r.count end
table.sort(h, function(a, b) return a.count > b.count end)

print(string.format("%d line events over %d lines", n, #h))
print(string.format("%10s %10s  %s", "count", "cpu_us", "where"))
for i = 1, math.min(14, #h) do
	local r = h[i]

	print(string.format("%10d %10.0f  %s:%d", r.count,
	    r.cpu * 1000 // cyc, r.source, r.line))
end
