-- sys.stack on a proc that is RUNNING, which is the case the whole
-- quiesce mechanism exists for.
--
-- Every other stack test reads a proc that is parked, and a parked proc
-- was safe to read even when the machine had one cpu. What was never
-- safe once there were two is reading a proc that is executing: it is
-- pushing and popping frames while the reader walks them.
--
-- Refusing would have been easy and useless. A spinning proc is running
-- by definition, and a spinning proc is exactly the one worth sampling
-- -- "where is it stuck" is the question. So the kernel holds the
-- target still (kproc.frozen, see proc_freeze) rather than declining.
--
-- What this asserts is only what a test can honestly assert: that the
-- sample comes back, that it names the spinner's own source rather than
-- the scheduler's, and that the target is running again afterwards. A
-- race that has been fixed cannot be proven absent by a passing test;
-- what it can do is fail loudly if the freeze is ever dropped, because
-- reading a moving stack faults or reports nonsense rather than being
-- quietly wrong.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(5)

local me = sys.sendright(0)

-- a proc that never blocks: it spins in a loop of its own, so it is
-- always either running or on a run queue, never parked
local spinner = [[
	local sys = require("los.sys")
	local a = ...
	local n = 0

	sys.send(a.reply.__right, "up")
	while true do
		n = n + 1			-- LINE 8: what a sample should name
		if n % 5000000 == 0 then
			sys.send(a.reply.__right, "alive")
		end
	end
]]

local pid = sys.spawn(spinner, { name = "spinner",
    arg = { reply = { __right = me } } })

tap.ok(pid ~= nil, "the spinner spawned")

-- wait for it to actually be running before sampling: sampling a proc
-- that has not started yet would pass for the wrong reason
local up = false

while not up do
	local ok, m = sys.tryrecv(0)

	if ok and m == "up" then
		up = true
	elseif not ok then
		sys.yield()
	end
end
tap.ok(up, "and reached its loop")

-- sample it repeatedly. Once could get lucky; the point is that every
-- one of these lands on a proc that is genuinely mid-execution.
local samples, own, err = 0, 0, nil

for _ = 1, 20 do
	local ok, co = pcall(sys.stack, pid)

	if not ok then
		err = co
		break
	end
	samples = samples + 1
	for _, c in ipairs(co) do
		for _, f in ipairs(c.frames or {}) do
			-- its own chunk, not lib/thread or the kernel: a
			-- bare spawn like this has no scheduler in it
			if tostring(f.source):match("spinner") then
				own = own + 1
			end
		end
	end
end

if err then
	tap.diag("sys.stack raised: " .. tostring(err))
end
tap.ok(samples == 20, "twenty samples of a running proc all returned")
tap.ok(own > 0, "at least one named the spinner's own source")

-- and it is not frozen afterwards: the thaw ran, so it is still making
-- progress. Its "alive" messages are the evidence.
local alive = false
local deadline = sys.uptime_ms() + 8000

while not alive and sys.uptime_ms() < deadline do
	local ok, m = sys.tryrecv(0)

	if ok and m == "alive" then
		alive = true
	elseif not ok then
		sys.yield()
	end
end
tap.ok(alive, "the spinner still runs after being sampled")

sys.kill(pid)
tap.done()
