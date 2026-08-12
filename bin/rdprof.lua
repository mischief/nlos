-- Where a readdir's time goes inside the server, by line.
--
-- The host runs the whole readdir stack in 2.6us an entry. The board
-- charges 3.3ms. That gap is not the message -- a reply carrying 73
-- entries costs 7ms, against the readdir's 242 -- so it is work, and
-- this asks the server which lines are doing it.
--
-- Arming a trace costs the traced proc about 4.7x, so read the shares
-- rather than the absolute numbers.
local sys = require("los.sys")
local ps = require("ps")
local prog = require("prog")
local unistd = require("posix.unistd")

local N = assert(prog.ns(), "rdprof: no namespace")
local path = (arg and arg[1]) or "/lib"
local rounds = tonumber(arg and arg[2]) or 5

local who
for _, pid in ipairs(sys.procs()) do
	if sys.name(pid) == "fatsrv" then who = pid end
end

if not who then
	print("rdprof: no fatsrv")
	return
end

local armed, aerr = pcall(sys.set_trace, who, 20000)

if not armed then
	print("rdprof: cannot trace pid " .. who .. ": " .. tostring(aerr))
	return
end

for _ = 1, rounds do N:readdir(path) end

-- read the ring before disarming: turning the trace off frees it
local ok, out = pcall(ps.tracehist, who, 24)

pcall(sys.set_trace, who, 0)
unistd.write(1, (ok and out or tostring(out)) .. "\n")
