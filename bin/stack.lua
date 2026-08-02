-- stack [pid]: where a proc is, right now.
--
-- Safe to call on anything, including a wedged proc, because every proc
-- but the caller is suspended between resumes -- there is no moment when
-- a stack is half-built.
--
-- ---- read the output knowing this ----
--
-- sys.stack walks the proc's MAIN coroutine, and lib/thread runs its
-- threads as coroutines inside that. So a proc built on lib/thread --
-- svc/sshd.lua, and anything else with more than one thing to wait on --
-- reports its SCHEDULER, not whichever thread is actually stuck:
--
--   1 [C]:-1 altblock (C)
--   2 /lib/thread.lua:84 run (Lua)
--   3 sshd:446 ? (main)
--
-- which is the same three frames whether it is idle or deadlocked. That
-- cost real time once: a session hung on a reply that was never coming,
-- and this said only "in the scheduler", exactly as it does when
-- everything is fine. Descending into lib/thread's coroutines needs no
-- kernel change -- debug.traceback takes a coroutine -- and is the
-- obvious next thing for this program to grow.

local unistd = require("posix.unistd")

local ok, ps = pcall(require, "ps")

if not ok then
	unistd.write(2, "stack: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

local sys = require("los.sys")
local pid = arg[1] and tonumber(arg[1]) or sys.self()

if not pid then
	unistd.write(2, "usage: stack [pid]\n")
	os.exit(2)
end

local got, out = pcall(ps.stack, pid)

if not got then
	unistd.write(2, "stack: " .. tostring(out) .. "\n")
	os.exit(1)
end

unistd.write(1, out .. "\n")
