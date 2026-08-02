-- ps: what the machine is running.
--
-- The repl has had this all along, as a bare word: lib/ps.lua's proxy
-- table computes at print time, so typing `ps` with no parentheses is
-- enough there. A dos shell has no bare-word globals, so the same
-- formatter needs a program in front of it -- and a session over ssh or
-- a browser reaches /bin, not the repl's _ENV.
--
-- No capability is required and none is granted: sys.procs, sys.name,
-- sys.meminfo, sys.priority and sys.wchan are all ambient, being
-- observations of the machine rather than authority over it. Worth
-- knowing rather than assuming, though -- a visitor handed a shell can
-- see every proc's name and memory. That is the same bargain webterm
-- already makes, not a new one.

local unistd = require("posix.unistd")

local ok, ps = pcall(require, "ps")

if not ok then
	unistd.write(2, "ps: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

unistd.write(1, tostring(ps.ps) .. "\n")
