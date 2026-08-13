-- stack [pid]: where a proc is, right now.
--
-- Safe to call on anything, including a wedged proc, because every proc
-- but the caller is suspended between resumes -- there is no moment when
-- a stack is half-built.
--
-- Reports every coroutine of the proc, not only its main one. That
-- distinction is the whole value: a proc built on lib/thread keeps its
-- threads as coroutines inside its own state, so reporting just the
-- main one showed the SCHEDULER -- alt / thread.run / entrypoint,
-- identical whether the proc was idle or deadlocked. src/debug.c walks
-- the target state for the rest.

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
