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

	-- machine memory as well as our own, since what is left in the
	-- firmware's pool is what bounds how many procs can exist.
	--
	-- heap= is every C allocation, the shared lua heap's chunks
	-- included, so it is not additive with lua=. lua= is that heap:
	-- what the states between them asked for, over what the machine
	-- holds to serve it. sys.meminfo(pid) has one proc's share of the
	-- first number.
	local live = s.lua_live or 0
	local mapped = s.lua_mapped or 0

	return string.format(
	    "procs=%d ports=%d heap=%dK lua=%dK/%dK (%.2fx) mem=%dK/%dK free",
	    s.procs, s.ports, (s.heap_used or 0) // 1024,
	    live // 1024, mapped // 1024,
	    live > 0 and mapped / live or 0,
	    (s.memavail or 0) // 1024, (s.memtotal or 0) // 1024)
end
M.stats = setmetatable({}, stats_mt)

-- stack(pid): where another proc actually is, not just what it is
-- blocked on. a factory rather than a bare value because it takes an
-- argument, so unlike ps/stats it is a plain function and the
-- __tostring question never arises.
-- sys.stack returns one entry per COROUTINE, not a flat frame list: a
-- proc built on lib/thread keeps its threads inside its own state, and
-- reporting only the main one showed the scheduler parked in altblock
-- whether the proc was idle or wedged. src/debug.c finds the rest.
function M.stack(pid)
	local coros = sys.stack(pid)
	local out = { string.format("%s (pid %d) %s", sys.name(pid), pid,
	    sys.wchan(pid)) }

	for _, co in ipairs(coros) do
		out[#out + 1] = string.format("  [%s] %s", co.label,
		    co.status)
		for i, f in ipairs(co.frames) do
			out[#out + 1] = string.format("    %2d %s:%d in %s",
			    i, f.source, f.line, f.name)
		end
		if #co.frames == 0 then
			out[#out + 1] =
			    "     (no frames -- dead or never started)"
		end
	end
	return table.concat(out, "\n")
end

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
