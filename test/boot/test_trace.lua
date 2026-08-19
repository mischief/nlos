-- sys.set_trace: the last N lines a proc executed, in a ring.
--
-- a stack says where a proc is, which after a fault is the wrong
-- question -- it shows the calls still open, not the ones that returned
-- on the way in. the trace is the other half, and it is worth keeping
-- only because a broke proc lives long enough to be read (test_broke).
--
-- what this file mostly guards is the hook, because the trace shares one
-- with the scheduler. two ways that goes wrong, both pinned below:
--
--   1. LUA_MASKCOUNT is the preemption budget. tracing may only ever add
--      LUA_MASKLINE to it, and turning tracing off must not take the
--      count with it -- a proc whose count hook went missing holds the
--      whole machine until it blocks. every mask in the kernel comes
--      from proc_hookmask for exactly this reason.
--   2. lua_newthread copies hook, mask and count when a coroutine is
--      created and never looks again (lua/lstate.c). so a mask set on
--      one coroutine reaches no other, and a proc on lib/thread would
--      have its scheduler traced and none of its threads. arming has to
--      walk the proc, which is what debug_sethook_all does.
--
-- if the preemption cases regress this test times out rather than
-- failing, the same inconvenient verdict test_preempt gives: a starved
-- machine cannot report on itself.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(21)

-- ---- a trace of another proc ----

local _, h = sys.spawn([[
	local sys = require("los.sys")
	local function step(n) return n + 1 end
	local i = 0
	while true do
		i = step(i)
		sys.yield()
	end
]], { name = "walker" })

local pid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "walker" then pid = p end
end
tap.ok(pid ~= nil, "the target proc started")
if not pid then tap.done() return end

tap.ok(#sys.trace(pid) == 0, "a proc with no trace reports an empty one")

tap.ok(sys.set_trace(pid, 64), "tracing can be turned on")
thread.sleep(30)

local tr = sys.trace(pid)

tap.ok(#tr > 0, "lines were recorded (" .. #tr .. ")")
tap.ok(#tr <= 64, "and the ring never exceeds its size (" .. #tr .. ")")

local sourced, lined = true, true

-- markers are entries too, and deliberately not lines: trace_mark writes
-- a context switch as source "<scheduled>" with line 0, so the gap it
-- covers has somewhere honest to sit instead of inflating whichever line
-- ran last. Anything else with no line number is the bug this asserts.
local function marker(e)
	return type(e.source) == "string" and e.source:sub(1, 1) == "<" and
	    e.line == 0
end

for _, e in ipairs(tr) do
	if type(e.source) ~= "string" or e.source == "?" then sourced = false end
	if not marker(e) and (type(e.line) ~= "number" or e.line <= 0) then
		lined = false
	end
end
tap.ok(sourced, "every entry names its source")
tap.ok(lined, "every entry is a line, or a marker that says it is not")

-- the ring is a ring: it holds the LAST n lines, not the first
local seen = {}

for _, e in ipairs(tr) do seen[e.line] = true end
tap.ok(seen[5] or seen[6], "the loop body is in the trace")

-- the ring has to wrap, and the walker above sleeps too much to make it.
-- a tight loop with a ring smaller than the number of lines it runs is
-- what exercises the modulo, and what proves the ring keeps the LAST n
-- lines rather than the first n and then stopping.
local _, hw = sys.spawn([[
	local i = 0
	while true do
		i = i + 1
		i = i + 2
		i = i + 3
	end
]], { name = "wrapper" })

local wpid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "wrapper" then wpid = p end
end

sys.set_trace(wpid, 8)
thread.sleep(20)

local wr = sys.trace(wpid)

tap.is(#wr, 8, "a ring smaller than the run wraps and stays full")

-- every surviving entry is from the loop body: lines 1 and 2 run once,
-- at the start, and a ring that kept the first n would still hold them
local body = true

for _, e in ipairs(wr) do
	if e.line < 3 then body = false end
end
tap.ok(body, "and what it kept is the most recent lines, not the first")

-- preemption while the line hook is armed, not just after it is gone:
-- we are only running to make this assertion because the spinner above
-- is yielding
tap.ok(true, "the machine is responsive with a spinner traced")
sys.set_trace(wpid, 0)
sys.close(hw)

tap.ok(sys.set_trace(pid, 0), "tracing can be turned off")
tap.ok(#sys.trace(pid) == 0, "and the ring is released")

sys.close(h)

-- ---- the hook must survive both edges ----
--
-- a spinner in a proc that has had tracing turned on and back off again.
-- if either transition dropped LUA_MASKCOUNT this never yields and the
-- test times out.
local _, h2 = sys.spawn([[
	local sys = require("los.sys")
	sys.send(0, "up")
	local i = 0
	while true do i = i + 1 end
]], { name = "spinner" })

local spid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "spinner" then spid = p end
end

sys.set_trace(spid, 32)
thread.sleep(10)
sys.set_trace(spid, 0)

-- we are only still running if the spinner is being preempted
local alive = 0

for _ = 1, 5 do
	thread.sleep(5)
	alive = alive + 1
end
tap.is(alive, 5, "a spinner is still preempted after tracing off")
sys.close(h2)

-- ---- every coroutine, not just the scheduler ----
--
-- the trap: lua_newthread copies the hook at creation time, so arming
-- p->co alone would trace the scheduler and none of the threads that
-- were already running -- which for a lib/thread proc is all the code
-- worth tracing.
local _, h3 = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	thread.spawn(function()
		while true do
			local x = 1 + 1
			thread.sleep(2)
		end
	end)
	thread.spawn(function()
		while true do
			local y = 2 + 2
			thread.sleep(2)
		end
	end)
	thread.run()
]], { name = "threaded" })

local tpid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "threaded" then tpid = p end
end

-- let both threads exist BEFORE tracing is armed: a hook applied only
-- to p->co would miss them entirely
thread.sleep(30)
sys.set_trace(tpid, 256)
thread.sleep(30)

local threads = {}
local nthreads = 0

for _, e in ipairs(sys.trace(tpid)) do
	if not threads[e.thread] then
		threads[e.thread] = true
		nthreads = nthreads + 1
	end
end
tap.ok(nthreads >= 2,
    "coroutines created before arming are traced too (" .. nthreads .. ")")
sys.set_trace(tpid, 0)
sys.close(h3)

-- ---- the payoff: a trace on a corpse ----
--
-- armed at spawn, which is the only way to reach a proc that faults
-- immediately: spawning and then arming is a race the proc wins, and by
-- the time it is broke the lines are already gone.
local _, h4 = sys.spawn([[
	local function inner() error("boom") end
	local function outer() inner() end
	local x = 1
	x = x + 1
	outer()
]], { name = "dier", trace = 64 })

local dpid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "dier" then dpid = p end
end
sys.monitor(dpid)

local note
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == dpid then note = m end
until note

-- the state is held, so the ring it belongs to is held with it
local dead = sys.trace(dpid)

tap.ok(#dead > 0, "a corpse still has its trace (" .. #dead .. " lines)")

local last = dead[#dead]

tap.diag(("last line executed: %s:%d"):format(last.source, last.line))
tap.ok(last.line >= 1, "and it ends where the proc did")

-- the lua surface reads the same corpse: lib/ps.lua's pretty printer
-- and the /proc file, which exists so a debugger is `cat /proc/n/trace`
-- rather than a program
local ps = require("ps")
local text = ps.trace(dpid)

tap.ok(text:find("dier:"), "ps.trace formats a corpse's ring")
tap.diag(text)

local ns = require("ns")
local espfs = require("espfs")
local procfs = require("procfs")
local N = ns.new()

N:mount("/", espfs.new("/"), "espfs", { root = "/" })
N:mount("/proc", procfs.new(), "procfs")

local pf = N:readfile("/proc/" .. dpid .. "/trace")

tap.ok(pf and pf:find("dier:"), "/proc/<pid>/trace serves it too")

-- arming a corpse can only ever produce an empty ring, which reads as
-- "this proc ran no lines" rather than "you are too late", so it is
-- refused rather than quietly accepted
local late, lerr = pcall(sys.set_trace, dpid, 32)

tap.ok(not late, "arming a corpse fails instead of quietly doing nothing")
tap.ok(tostring(lerr):find("broke"), "and says why: " .. tostring(lerr))

sys.reap(dpid)
sys.close(h4)

tap.done()
