-- the other cpus started.
--
-- This is all a proc can currently ask, and it is asked from inside
-- rather than by watching qemu because the failure it is looking for is
-- silent: an AP that never leaves the trampoline leaves nothing behind,
-- and the machine boots and passes every other test exactly as if it
-- had been given one cpu. So the count has to be reported by the kernel
-- that started them (sys.stats().cpus) and compared against what the
-- harness asked for.
--
-- What it does not say: that anything runs on those cpus. They are
-- parked in hlt at this commit. When the scheduler is per-cpu, the
-- honest test of that is wall time against the uniprocessor build,
-- measured from the host -- not a count read from inside.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(3)

local m = sys.stats()

tap.diag("arch " .. tostring(m.arch) .. ", cpus " .. tostring(m.cpus))

tap.ok(type(m.cpus) == "number", "sys.stats() reports a cpu count")

-- the harness runs this with -smp 2. Hardcoding the 2 rather than
-- passing it in keeps the test honest about what it is checking: if
-- the flag stops reaching qemu, this fails rather than agreeing with
-- whatever it was given.
tap.ok(m.cpus == 2, "both cpus came up, not just the boot processor")

-- the kernel still works after starting them. An AP that came up on
-- the BSP's stack, or that took the boot processor's page tables away
-- while it was using them, would show here rather than in the count.
local got = 0
local me = sys.sendright(0)
local pid = sys.spawn([[
	local sys = require("los.sys")
	sys.send((...).__right, "alive")
]], { arg = { __right = me } })

while got < 1 do
	local ok = sys.tryrecv(0)
	if ok then got = got + 1 else sys.yield() end
end

tap.ok(pid and got == 1, "the machine still schedules after bring-up")

tap.done()
