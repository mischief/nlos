-- magic repl commands: proxy tables whose __tostring metamethod runs
-- live at print-time. init.lua's repl already feeds bare expressions
-- through print(), and print() consults __tostring -- so typing the
-- bare word (no parens) is enough to compute+format fresh output.
local sys = require("los.sys")

local M = {}

-- The columns, widest-useful first in `drop` order.
--
-- A column is as wide as the widest thing in it, heading included, so a
-- machine whose pids are one digit does not spend five characters
-- saying so. That alone takes the line from 66 columns to about 50,
-- which is what makes it readable on the 53-column panel.
--
-- `drop` orders what goes when it still does not fit: the lowest number
-- leaves first. pid and name have no drop and never leave -- a row that
-- cannot say which proc it describes is not worth printing. pri is
-- first out because nothing dispatches on it yet.
--
-- `max` caps the two free-text columns. One proc with a long name would
-- otherwise set the width for every row, and losing the tail of one
-- name costs less than losing a whole column.
local PSCOLS = {
	{ head = "PID", key = "pid" },
	{ head = "NAME", key = "name", left = true, max = 16 },
	{ head = "USED", key = "used", drop = 7 },
	{ head = "PEAK", key = "peak", drop = 3 },
	{ head = "WT", key = "weight", drop = 2 },
	{ head = "PRI", key = "pri", drop = 1 },
	{ head = "CPU", key = "cpu", drop = 5 },
	{ head = "RESUMES", key = "resumes", drop = 4 },
	{ head = "WCHAN", key = "wchan", left = true, max = 12, drop = 6 },
}

-- cpu is per-mille of wall time, decayed from the tsc.
--
-- resumes is the count next to that rate: cpu says how much of the
-- machine a proc is taking, resumes says in how many pieces. A server
-- round-tripping on ipc shows a small cpu over a large count, and that
-- ratio is what says whether a proc is working or waiting.
local function psrows()
	local rows = {}

	for _, pid in ipairs(sys.procs()) do
		-- one call per proc rather than one per column: name,
		-- meminfo, priority and wchan are still there, but a row
		-- built from them cost four kernel entries and grew one
		-- more every time a column was added.
		rows[#rows + 1] = sys.pidstat(pid)
	end
	return rows
end

-- Lay a table out in `width` columns, or in as many as it wants when
-- nothing knows the width -- in which case only the sizing applies and
-- no column is dropped.
--
-- spec is the column list above; rows are records it reads by key.
local function fmttable(spec, rows, width)
	local cols, cells, wide = {}, {}, {}

	for _, c in ipairs(spec) do
		local w = #c.head
		local column = {}

		for i, s in ipairs(rows) do
			local v = tostring(s[c.key] or "")

			if c.max and #v > c.max then
				v = v:sub(1, c.max)
			end
			column[i] = v
			if #v > w then
				w = #v
			end
		end
		cols[#cols + 1] = c
		cells[c] = column
		-- beside the spec rather than on it: the spec is a
		-- module-level constant, shared by every call.
		wide[c] = w
	end

	-- drop until it fits, lowest drop first. A column with no drop
	-- stays whatever happens, so this always terminates.
	local function linewidth()
		local n = -1	-- no trailing space after the last column

		for _, c in ipairs(cols) do
			n = n + wide[c] + 1
		end
		return n
	end

	while width and linewidth() > width do
		local worst, at

		for i, c in ipairs(cols) do
			if c.drop and (not worst or c.drop < worst.drop) then
				worst, at = c, i
			end
		end
		if not worst then
			break		-- only the columns that never leave
		end
		table.remove(cols, at)
	end

	local out = {}

	for i = 0, #rows do
		local line = {}

		for _, c in ipairs(cols) do
			local v = (i == 0) and c.head or cells[c][i]

			line[#line + 1] = string.format(
			    c.left and ("%-" .. wide[c] .. "s")
			    or ("%" .. wide[c] .. "s"), v)
		end
		-- the last column is not padded: a trailing run of spaces
		-- costs a wrapped line on a terminal exactly as wide as the
		-- table, which is precisely the case this fits to.
		out[#out + 1] = table.concat(line, " "):gsub("%s+$", "")
	end
	return table.concat(out, "\n")
end

-- width is the terminal's, or nil when nothing knows it.
function M.psfmt(width)
	return fmttable(PSCOLS, psrows(), width)
end

-- the bare word in the repl, which has no width to offer.
local ps_mt = {}
ps_mt.__tostring = function()
	return M.psfmt(nil)
end
M.ps = setmetatable({}, ps_mt)

-- a single cell's resting voltage against its charge, in millivolts.
-- Li-ion is flat across the middle and steep at both ends, so a linear
-- reading of volts would sit at "half full" for most of a discharge.
-- Interpolated between the points, clamped outside them.
local CURVE = {
	{ 3000, 0 }, { 3300, 10 }, { 3600, 25 }, { 3700, 40 },
	{ 3800, 60 }, { 3950, 80 }, { 4100, 95 }, { 4200, 100 },
}

-- above a cell's own maximum, something external is holding the pin up:
-- the charger, which on the T-Deck sits across the divider. So a
-- reading over the top of the curve is how charging is detected, there
-- being no status pin to ask. Measured: 4.03V on the pack alone against
-- 4.64V on USB.
local CHARGING = 4250

-- battery() -> millivolts, percent, charging. Nothing where no pack.
function M.battery()
	local mv = sys.battery and sys.battery()

	if not mv then
		return nil
	end
	if mv >= CHARGING then
		return mv, 100, true
	end
	if mv <= CURVE[1][1] then
		return mv, 0, false
	end
	for i = 2, #CURVE do
		local lo, hi = CURVE[i - 1], CURVE[i]

		if mv <= hi[1] then
			local f = (mv - lo[1]) / (hi[1] - lo[1])

			return mv, math.floor(lo[2] + f * (hi[2] - lo[2]) + 0.5),
			    false
		end
	end
	return mv, 100, false
end

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

	-- the chunk pool, where it is not the memory reported above: on a
	-- board with PSRAM the heaps are there and everything else is in
	-- internal sram, and it is this pool that bounds how many procs
	-- there can be. Shown only when the two differ, since on every
	-- other machine it would be the same number twice.
	local chunk = ""

	if (s.chunktotal or 0) > 0 and s.chunktotal ~= s.memtotal then
		chunk = string.format(" chunks=%dK/%dK free max=%dK",
		    (s.chunkavail or 0) // 1024, s.chunktotal // 1024,
		    (s.chunklargest or 0) // 1024)
	end

	-- the battery, where there is one. Absent on every machine that
	-- runs on wall power, which is most of them.
	local mv, pct, chg = M.battery()
	local bat = mv and string.format(" bat=%d%% %.2fV%s", pct,
	    mv / 1000, chg and " chg" or "") or ""

	-- max is the largest single free run. Free bytes scattered below
	-- what a chunk costs buy nothing, and say nothing about it.
	return string.format(
	    "procs=%d%s ports=%d heap=%dK lua=%dK/%dK (%.2fx) " ..
	    "mem=%dK/%dK free max=%dK%s%s",
	    s.procs, broke, s.ports, (s.heap_used or 0) // 1024,
	    live // 1024, mapped // 1024,
	    live > 0 and mapped / live or 0,
	    (s.memavail or 0) // 1024, (s.memtotal or 0) // 1024,
	    (s.memlargest or 0) // 1024, chunk, bat)
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
-- Sized and dropped as the ps table is, and for the same reason: 64
-- fixed columns wrapped every row on the panel.
--
-- The two drop counts leave last of the droppable columns, being the
-- reason to look at all. qlen goes before qpeak, which is the one that
-- catches a queue that has already drained.
local PORTCOLS = {
	{ head = "IDX", key = "port" },
	{ head = "OWNER", key = "who", left = true, max = 14 },
	{ head = "R", key = "rights", drop = 2 },
	{ head = "RCV", key = "recv", drop = 1 },
	{ head = "QLEN", key = "qbytes", drop = 3 },
	{ head = "QPEAK", key = "qpeak", drop = 5 },
	{ head = "SENT", key = "sent", drop = 4 },
	{ head = "DROPF", key = "dropfull", drop = 7 },
	{ head = "DROPD", key = "dropdead", drop = 6 },
}

local function portrows()
	local rows = {}

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

		p.who = who
		rows[#rows + 1] = p
	end
	return rows
end

function M.portsfmt(width)
	return fmttable(PORTCOLS, portrows(), width)
end

local ports_mt = {}
ports_mt.__tostring = function()
	return M.portsfmt(nil)
end
M.ports = setmetatable({}, ports_mt)

-- stack(pid): where another proc actually is, not just what it is
-- blocked on. a factory rather than a bare value because it takes an
-- argument, so unlike ps/stats it is a plain function and the
-- __tostring question never arises.
-- sys.stack returns one entry per COROUTINE, not a flat frame list: a
-- proc built on lib/thread keeps its threads inside its own state, and
-- reporting only the main one showed the scheduler parked in alt
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

-- reboot: halt's other half, and the same rules -- a factory for the
-- capability, an effect only on call, nothing from __tostring.
--
-- The stall goes first so the word "rebooting" reaches the serial line:
-- both are sends to one mailbox and arrive in order. Without it the
-- machine resets with the line still in the uart and prints nothing,
-- which reads as a crash.
function M.reboot(powerhandle)
	return setmetatable({}, {
		__tostring = function()
			return "reboot: type reboot() to restart the machine"
		end,
		__call = function(_, mode)
			sys.send(powerhandle, { op = "stall", us = 100000 })
			sys.send(powerhandle,
			    { op = "reset", mode = mode or "cold" })
			return "rebooting..."
		end,
	})
end

return M
