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

local ok, ps = pcall(require, "ps")

if not ok then
	io.stderr:write("trace: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

local sys = require("los.sys")
local getopt = require("getopt")

local flags, optind = getopt.parse(arg, "n:h")

if not flags then
	io.stderr:write("trace: " .. optind .. "\n")
	os.exit(2)
end

local n = flags.n and tonumber(flags.n)

if flags.n and not n then
	io.stderr:write("trace: -n wants a number\n")
	os.exit(2)
end

-- two operands are rows then pid; a lone one is the pid
local hist, rows, pid = flags.h, nil, nil

if arg[optind + 1] then
	rows = tonumber(arg[optind])
	pid = tonumber(arg[optind + 1])
else
	pid = tonumber(arg[optind])
end

pid = pid or sys.self()

if n then
	local armed, err = pcall(sys.set_trace, pid, n)

	if not armed then
		io.stderr:write("trace: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	io.write(string.format(
	    "tracing pid %d, %d lines; read it back with `trace %d`\n",
	    pid, n, pid))
	return
end

local got, out = pcall(hist and ps.tracehist or ps.trace, pid, rows)

if not got then
	io.stderr:write("trace: " .. tostring(out) .. "\n")
	os.exit(1)
end

io.write(out .. "\n")
