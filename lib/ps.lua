-- magic repl commands: proxy tables whose __tostring metamethod runs
-- live at print-time. init.lua's repl already feeds bare expressions
-- through print(), and print() consults __tostring -- so typing the
-- bare word (no parens) is enough to compute+format fresh output.
local sys = require("los.sys")

local M = {}

local ps_mt = {}
ps_mt.__tostring = function()
	local lines = { "  PID NAME                 USED      PEAK  WT PRI  CPU WCHAN" }
	for _, pid in ipairs(sys.procs()) do
		local used, peak = sys.meminfo(pid)
		local wt, pri, cpu = sys.priority(pid)

		-- cpu is per-mille of wall time, decayed from the tsc.
		-- nothing dispatches on pri yet.
		lines[#lines + 1] = string.format(
		    "%5d %-16s %9d %9d %3d %3d %4d %s",
		    pid, sys.name(pid), used, peak, wt, pri, cpu,
		    sys.wchan(pid))
	end
	return table.concat(lines, "\n")
end
M.ps = setmetatable({}, ps_mt)

local stats_mt = {}
stats_mt.__tostring = function()
	local s = sys.stats()
	return string.format("procs=%d ports=%d", s.procs, s.ports)
end
M.stats = setmetatable({}, stats_mt)

-- halt: unlike ps/stats above, which only report, this one has a real
-- side effect -- so it deliberately does NOT fire from __tostring.
-- printing it explains itself; calling it shuts the machine down.
--
-- it did fire from __tostring once, and the failure is worth
-- remembering: `for k, v in pairs(_G) do print(k, v) end` powered the
-- machine off. tostring is assumed pure by everything that introspects
-- -- print, tab completion, a debugger, error formatters dumping
-- locals, luaL_traceback -- so a side-effecting __tostring is a
-- landmine that any traversal steps on.
--
-- a factory rather than a bare value because it needs the power
-- capability, which is a handle the caller was granted (see caps.lua on
-- why no wrapper here defaults to a well-known number).
function M.halt(powerhandle)
	return setmetatable({}, {
		__tostring = function()
			return "halt: type halt() to shut the machine down"
		end,
		__call = function()
			sys.send(powerhandle, { op = "reset", mode = "shutdown" })
			return "halting..."
		end,
	})
end

return M
