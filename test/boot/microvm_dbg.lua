-- Debugging a proc that is genuinely running on another cpu.
--
-- Everything the debugger touches on a target -- its kdbg, the hooks on
-- its coroutines, its frames -- is safe only because proc_hold has
-- stopped it first, and on one cpu that was free: every proc but the
-- caller was suspended between resumes. Here it is not. The target
-- below spins without ever yielding, so at -smp 2 and above it is
-- executing while the debugger asks it to stop.
--
-- What a race looks like: the kernel's own "proc dispatched on two
-- cpus" assertion, a lua panic from a hook armed on a running state, or
-- a stop that never commits and hangs this test rather than failing it.
-- The loop count is what makes an unlikely window likely.

local sys = require("los.sys")
local dbg = require("los.dbg")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

-- Reported, not asserted. A loaded host gives qemu fewer vcpus than
-- asked for, and a count of one means the races below went untested
-- rather than that anything is wrong.
tap.diag("cpus " .. tostring(sys.stats().cpus))

local notice = sys.newport("microvm_dbg.notice")

-- a spinner: no yield, no block, no allocation. The only thing that
-- ever takes the cpu from it is the preemption hook.
local pid, h = sys.spawn([[
	local n = 0
	while true do n = n + 1 end
]], { name = "dbgspin" })

tap.ok(dbg.attach(pid, notice), "attach")

local ROUNDS = 200
local stops, misses = 0, 0

for _ = 1, ROUNDS do
	dbg.stop(pid)

	-- the stop is committed at the kernel boundary, which a spinner
	-- reaches within a quantum because the count hook cuts it.
	local ok = false

	for _ = 1, 500 do
		if sys.wchan(pid) == "stopped" then ok = true break end
		thread.yield()
	end
	if ok then
		stops = stops + 1
		-- while it is stopped it must be readable, and reading it
		-- must not race its execution: it has none.
		local st = dbg.status(pid)

		if not st.stopped then misses = misses + 1 end
		dbg.cont(pid)
	else
		misses = misses + 1
	end
end

tap.diag(("%d/%d stops, %d misses"):format(stops, ROUNDS, misses))
tap.ok(stops == ROUNDS, "every stop committed")
tap.ok(misses == 0, "and every stopped proc read as stopped")

-- the target survived all of it
tap.ok(sys.wchan(pid) ~= "broke", "the target did not break")

-- Attach and detach churn against a running target. dbg_free clears
-- and frees the state while another cpu may be walking the proc table
-- in dbg_sweep, so this is the shape that finds a use-after-free.
local churn = 0

for _ = 1, 200 do
	dbg.detach(pid)
	if dbg.attach(pid, notice) then churn = churn + 1 end
	if churn % 3 == 0 then
		dbg.stop(pid)
		for _ = 1, 500 do
			if sys.wchan(pid) == "stopped" then break end
			thread.yield()
		end
		-- detach would resume it too; cont is the path with the
		-- rearm in it.
		if sys.wchan(pid) == "stopped" then dbg.cont(pid) end
	end
end
tap.diag(("%d attach/detach cycles"):format(churn))
tap.ok(churn == 200, "attach and detach survive a running target")
tap.ok(sys.wchan(pid) ~= "broke", "and it is still alive after")

dbg.detach(pid)
sys.kill(pid)
sys.close(h)
sys.close(notice)
tap.done()
