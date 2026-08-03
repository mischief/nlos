-- magic repl commands: proxy tables whose __tostring metamethod runs
-- live at print-time. init.lua's repl already feeds bare expressions
-- through print(), and print() consults __tostring -- so typing the
-- bare word (no parens) is enough to compute+format fresh output.
local sys = require("los.sys")

local M = {}

-- one format for the heading and the rows, so a column cannot be
-- widened without its heading moving with it. Hand-spacing the heading
-- is what put everything from USED rightwards a column left of the
-- numbers under it.
--
-- %s throughout rather than %d: it formats integers identically at the
-- same width, and it is the only way one format string can serve both.
local PSFMT = "%5s %-16s %9s %9s %3s %3s %4s %9s %s"

local ps_mt = {}
ps_mt.__tostring = function()
	local lines = { string.format(PSFMT, "PID", "NAME", "USED", "PEAK",
	    "WT", "PRI", "CPU", "RESUMES", "WCHAN") }
	for _, pid in ipairs(sys.procs()) do
		-- one call per proc rather than one per column: name,
		-- meminfo, priority and wchan are still there, but a row
		-- built from them cost four kernel entries and grew one
		-- more every time a column was added.
		local s = sys.pidstat(pid)

		-- cpu is per-mille of wall time, decayed from the tsc.
		-- nothing dispatches on pri yet.
		--
		-- resumes is the count next to that rate: cpu says how much
		-- of the machine a proc is taking, resumes says in how many
		-- pieces. A server round-tripping on ipc shows a small cpu
		-- over a large count, and that ratio is what says whether a
		-- proc is working or waiting.
		lines[#lines + 1] = string.format(PSFMT,
		    s.pid, s.name, s.used, s.peak, s.weight, s.pri, s.cpu,
		    s.resumes, s.wchan)
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

	-- corpses only when there are any: a held broke proc is a thing
	-- to go and look at with stack(pid), and a permanent "broke=0"
	-- on a healthy machine would be noise rather than news.
	local broke = (s.broke or 0) > 0
	    and string.format(" broke=%d", s.broke) or ""

	return string.format(
	    "procs=%d%s ports=%d heap=%dK lua=%dK/%dK (%.2fx) mem=%dK/%dK free",
	    s.procs, broke, s.ports, (s.heap_used or 0) // 1024,
	    live // 1024, mapped // 1024,
	    live > 0 and mapped / live or 0,
	    (s.memavail or 0) // 1024, (s.memtotal or 0) // 1024)
end
M.stats = setmetatable({}, stats_mt)

-- ports: where messages are going, and what is being refused.
--
-- The two drop columns are the reason this exists. A task cannot see
-- its own refused sends as anything but a boolean, and it cannot see
-- another port's at all -- so a stack that has fallen behind and one
-- that is merely quiet look identical from every vantage point except
-- this one.
--
-- QPEAK earns its column over QLEN: a queue is rarely looked at while
-- it is deep. One that touched MAXQUEUE and drained shows QLEN 0, and
-- is exactly the port worth asking about.
local PORTFMT = "%4s %-14s %3s %3s %6s %6s %8s %6s %6s"

local ports_mt = {}
ports_mt.__tostring = function()
	local lines = { string.format(PORTFMT, "IDX", "OWNER", "R", "RCV",
	    "QLEN", "QPEAK", "SENT", "DROPF", "DROPD") }

	for _, p in ipairs(sys.ports()) do
		-- owner is whoever holds the receive right, and is absent
		-- rather than zero when nobody does -- pid 0 is the
		-- console, so zero could not have meant "nobody". A port
		-- has no holder once its receive right is closed, which is
		-- what dead means, or while one is in flight between procs.
		local who

		if p.owner then
			who = sys.name(p.owner)
		elseif p.dead then
			who = "(hungup)"
		else
			who = "-"
		end

		lines[#lines + 1] = string.format(PORTFMT,
		    p.port, who, p.rights, p.recv, p.qbytes, p.qpeak,
		    p.sent, p.dropfull, p.dropdead)
	end
	return table.concat(lines, "\n")
end
M.ports = setmetatable({}, ports_mt)

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

-- trace(pid): the last lines a proc ran, oldest first.
--
-- the companion to stack(). a stack shows the calls that are still
-- open, so after a fault it describes the shape of the failure and not
-- the route to it -- the call that returned just before everything went
-- wrong is exactly what it cannot show. runs of one line are collapsed
-- because a loop otherwise fills the ring with the same entry, and the
-- thread column is what keeps an interleaved lib/thread proc from
-- reading as one impossible execution.
function M.trace(pid)
	local tr = sys.trace(pid)
	local out = { string.format("%s (pid %d): last %d lines",
	    sys.name(pid), pid, #tr) }

	if #tr == 0 then
		out[#out + 1] = "  (not traced -- sys.set_trace(pid, n))"
		return table.concat(out, "\n")
	end

	local i = 1

	while i <= #tr do
		local e = tr[i]
		local n = 1

		while tr[i + n] and tr[i + n].line == e.line
		    and tr[i + n].source == e.source
		    and tr[i + n].thread == e.thread do
			n = n + 1
		end
		out[#out + 1] = string.format("  [%d] %s:%d%s", e.thread,
		    e.source, e.line, n > 1 and (" (x%d)"):format(n) or "")
		i = i + n
	end
	return table.concat(out, "\n")
end

-- tracehist(pid): the same ring, by cost rather than by order.
--
-- A trace answers "how did it get here". This answers "where does it
-- spend itself", which is a different question and needs the clock
-- rather than the sequence: the hottest line by count and the most
-- expensive line are routinely not the same one, and on the first task
-- this was pointed at they were nine executions apart.
--
-- cpu is what the line cost; wall minus cpu is how long the proc was
-- not running after it, which is where a blocking call shows up.
function M.tracehist(pid, top)
	local h = sys.tracehist(pid)
	local out = { string.format("%s (pid %d): %d lines by cost",
	    sys.name(pid), pid, #h) }

	if #h == 0 then
		out[#out + 1] = "  (not traced -- sys.set_trace(pid, n))"
		return table.concat(out, "\n")
	end

	local cyc = sys.stats().cycles_per_ms
	local total = 0

	for _, r in ipairs(h) do
		total = total + r.cpu
	end
	if total == 0 then
		total = 1
	end

	out[#out + 1] = "    cpu_us  blocked_us     %  count  where"
	for i = 1, math.min(top or 20, #h) do
		local r = h[i]

		out[#out + 1] = string.format(
		    "  %8.2f  %10.2f  %5.1f  %5d  %s:%d",
		    r.cpu * 1000 / cyc, (r.wall - r.cpu) * 1000 / cyc,
		    r.cpu / total * 100, r.count, r.source, r.line)
	end
	if h.dropped and h.dropped > 0 then
		out[#out + 1] = string.format(
		    "  (%d entries unaggregated -- allocation failed)",
		    h.dropped)
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
