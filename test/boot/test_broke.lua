-- a proc that dies of an error is held in BROKE, with its stack still
-- standing, until something reaps it.
--
-- the thing being pinned here is that the frames survive at all. a
-- coroutine that errors out of lua_resume does not unwind, which is
-- what lets luaL_traceback walk it in kernel_run -- and then the state
-- was closed one line later, so the frames existed for exactly the
-- length of that call. holding them instead costs nothing but the heap
-- the corpse sits in.
--
-- note what a corpse can and cannot catch. lib/thread's scheduler
-- resumes each thread under coroutine.resume and, on failure, prints
-- "thread error:" and drops it (resume_one in src/thread.c), so a fault inside
-- a thread never reaches lua_resume and never breaks the proc. what
-- breaks is what kills the proc: a fault in its main coroutine, the
-- deadlock error out of thread.run, or running out of memory. the
-- second spawn below is the one that matters for a threaded proc.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(20)

local _, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	local function deep() error("the fault") end
	local function middle() deep() end

	middle()
]], { name = "faulter" })

local pid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "faulter" then pid = p end
end
tap.ok(pid ~= nil, "the target proc started")
if not pid then tap.done() return end

sys.monitor(pid)

-- the exit notification must arrive at the moment of death, not at
-- reap: a parent that waited for the corpse to be released would be
-- waiting on a proc that is never coming back.
local note
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == pid then note = m end
until note

tap.ok(note ~= nil, "the monitor was notified")

tap.ok(note.normal == false, "reported as an abnormal exit")
tap.ok(note.broke == true, "the notification says a corpse is held")
tap.ok(type(note.reason) == "string" and note.reason:find("the fault"),
    "the reason carries the error")

tap.ok(sys.wchan(pid) == "broke", "the proc is in broke")

-- still listed: a corpse you cannot find is a corpse you cannot look at
local listed = false
for _, p in ipairs(sys.procs()) do
	if p == pid then listed = true end
end
tap.ok(listed, "a broke proc still appears in sys.procs")

-- but is not counted as one. sys.procs lists corpses so they can be
-- found; sys.stats counts what is alive, or every crash would read as
-- a leak in the one number people watch for leaks.
local st = sys.stats()

tap.ok(st.broke >= 1, "corpses are counted separately in sys.stats")

-- and it cannot be monitored: the notification for this death has
-- already been delivered, so a second monitor would be a wait for an
-- event in the past
sys.monitor(pid)
local again
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == pid then again = m end
until again
tap.is(again.reason, "noproc", "monitoring a corpse gives noproc at once")

-- the payoff. sys.stack needs no knowledge of broke at all: src/debug.c
-- reads a suspended state, and a corpse is one suspended forever.
local coros = sys.stack(pid)
local found

tap.ok(type(coros) == "table" and #coros >= 1, "the corpse has a stack")
for _, c in ipairs(coros or {}) do
	tap.diag(("%s (%s): %d frames"):format(c.label, tostring(c.status),
	    c.frames and #c.frames or 0))
	for _, f in ipairs(c.frames or {}) do
		if f.name == "deep" or f.name == "middle" then
			found = true
		end
	end
end
tap.ok(found, "the frames at the point of the error are still there")

tap.ok(sys.reap(pid), "the corpse can be reaped")

-- and is then gone entirely: find_proc skips DEAD, so the pid stops
-- resolving rather than resolving to something empty
tap.ok(not pcall(sys.wchan, pid), "the pid no longer resolves")

-- a threaded proc. the fault that kills one of these is the deadlock
-- error out of thread.run, and the corpse is worth more here than
-- anywhere else: the traceback it replaced could only ever describe
-- the scheduler, while the threads that are actually stuck are
-- coroutines src/debug.c has to go and find.
-- it waits for a go: on another cpu it would otherwise deadlock and die
-- before the monitor below is armed, and monitoring a corpse is answered
-- with noproc rather than with the death.
local _, h2 = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local go

	repeat
		sys.block(0)
		go = sys.tryrecv(0)
	until go

	-- parked on nothing pollable: gatherports() finds no ports and
	-- thread.run raises, which is a real proc death
	thread.spawn(function() thread._park({}) end)
	thread.spawn(function() thread._park({}) end)
	thread.run()
]], { name = "stuck" })

local spid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "stuck" then spid = p end
end
tap.ok(spid ~= nil, "the threaded proc started")
sys.monitor(spid)
sys.send(h2, { go = true })

local n2
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == spid then n2 = m end
until n2

tap.ok(n2.broke == true, "a deadlocked proc breaks too")

local scoros = sys.stack(spid)

tap.ok(type(scoros) == "table" and #scoros >= 1,
    "the deadlocked corpse has a stack")
for _, c in ipairs(scoros or {}) do
	tap.diag(("%s (%s): %d frames"):format(c.label, tostring(c.status),
	    c.frames and #c.frames or 0))
end
sys.reap(spid)

-- out of memory. this is the corpse that could not have been a
-- traceback: luaL_traceback allocates, so kernel_run skips it on
-- LUA_ERRMEM and the death has always been reported by one bare line.
-- reading it works only because src/debug.c allocates nothing in the
-- target -- the proc is at its limit, and a debugger that needed a
-- table in there would push it over while looking at it.
local _, h3 = sys.spawn([[
	local t = {}
	while true do t[#t + 1] = string.rep("x", 1024) end
]], { name = "hog", mem = 512 * 1024 })

local hpid
for _, p in ipairs(sys.procs()) do
	if sys.name(p) == "hog" then hpid = p end
end

sys.monitor(hpid)

local n3
repeat
	local m = thread.recv(sys.SELF)
	if type(m) == "table" and m.exit == hpid then n3 = m end
until n3

tap.ok(n3.broke == true, "an out-of-memory proc breaks")
local hcoros = sys.stack(hpid)

tap.ok(type(hcoros) == "table" and #hcoros >= 1,
    "and its stack is readable at the limit")

-- the cap. corpses are whole lua_States parked in the shared heap, so
-- they are a cache of recent deaths: breaking past MAXBROKE reaps the
-- oldest rather than accumulating.
local pids = {}

for i = 1, 3 do
	local _, hh = sys.spawn([[error("bang")]], { name = "bang" .. i })
	for _, p in ipairs(sys.procs()) do
		if sys.name(p) == "bang" .. i then pids[i] = p end
	end
	sys.monitor(pids[i])

	local m
	repeat
		m = thread.recv(sys.SELF)
	until type(m) == "table" and m.exit == pids[i]
	sys.close(hh)
end

-- the cap is a steady state, not an instant: the break that makes room
-- reaps the oldest corpse, and that teardown runs a lua_close. On
-- another cpu the exit notice can arrive while it is still going.
local held = 0
local deadline = sys.uptime_ms() + 4000

repeat
	held = 0
	for _, p in ipairs(pids) do
		local ok, w = pcall(sys.wchan, p)
		if ok and w == "broke" then held = held + 1 end
	end
	if held <= 2 then break end
	sys.yield()
until sys.uptime_ms() >= deadline
tap.ok(held <= 2, "no more than MAXBROKE corpses are held (" .. held .. ")")
tap.ok(select(2, pcall(sys.wchan, pids[3])) == "broke",
    "and the one kept is the most recent")

-- every reap is a pcall: the cap has already been taking corpses away
-- behind our back, which is the behaviour test 17 just asserted
for _, p in ipairs(pids) do pcall(sys.reap, p) end
pcall(sys.reap, hpid)
sys.close(h2)
sys.close(h3)

tap.done()
