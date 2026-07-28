-- magic repl commands: proxy tables whose __tostring metamethod runs
-- live at print-time. init.lua's repl already feeds bare expressions
-- through print(), and print() consults __tostring -- so typing the
-- bare word (no parens) is enough to compute+format fresh output.
local sys = require("los.sys")

local M = {}

local ps_mt = {}
ps_mt.__tostring = function()
	local lines = { "  PID NAME                 USED      PEAK     LIMIT   WT WCHAN" }
	for _, pid in ipairs(sys.procs()) do
		local used, peak, limit = sys.meminfo(pid)
		lines[#lines + 1] = string.format("%5d %-18s %9d %9d %9d %4d %s",
		    pid, sys.name(pid), used, peak, limit, sys.priority(pid),
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

return M
