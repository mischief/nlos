-- trace [-n entries] [-h [rows]] pid: what a proc ran, in order or by cost.
--
-- The companion to stack. A stack shows the calls that are still open,
-- which after a fault describes the shape of the failure rather than
-- the route to it -- the call that returned just before everything went
-- wrong is precisely what it cannot show.
--
-- With -n this arms a trace and returns; the lines accumulate as the
-- proc runs and are read by a later plain `trace pid`. Arming is a real
-- effect on the target rather than a report about it -- a line hook
-- fires per line instead of every REDUCTIONS instructions, costing the
-- traced proc about 4.7x -- so it is a separate invocation from the
-- dump rather than a flag that quietly does both.
--
-- Most useful on a broke proc, whose ring is held with its state until
-- it is reaped, so the trace and the stack answer for the same instant.

-- -h reads the same ring by cost instead of in order. Read it as a
-- proportion: the line hook charges the traced proc about 4.7x, and it
-- charges cheap lines most.

local unistd = require("posix.unistd")

local ok, ps = pcall(require, "ps")

if not ok then
	unistd.write(2, "trace: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

local sys = require("los.sys")
local n, pid, hist, rows

local i = 1

while arg[i] do
	if arg[i] == "-n" then
		i = i + 1
		n = tonumber(arg[i])
		if not n then
			unistd.write(2, "trace: -n wants a number\n")
			os.exit(2)
		end
	elseif arg[i] == "-h" then
		hist = true
		-- a bare number after -h is the row count, but a lone
		-- one is the pid, so it takes the second of two
		if tonumber(arg[i + 1]) and tonumber(arg[i + 2]) then
			i = i + 1
			rows = tonumber(arg[i])
		end
	else
		pid = tonumber(arg[i])
	end
	i = i + 1
end

pid = pid or sys.self()

if n then
	local armed, err = pcall(sys.set_trace, pid, n)

	if not armed then
		unistd.write(2, "trace: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	unistd.write(1, string.format(
	    "tracing pid %d, %d lines; read it back with `trace %d`\n",
	    pid, n, pid))
	return
end

local got, out = pcall(hist and ps.tracehist or ps.trace, pid, rows)

if not got then
	unistd.write(2, "trace: " .. tostring(out) .. "\n")
	os.exit(1)
end

unistd.write(1, out .. "\n")
