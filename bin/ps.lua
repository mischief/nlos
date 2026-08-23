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

local ok, ps = pcall(require, "ps")

if not ok then
	io.stderr:write("ps: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

-- the terminal's width, so the table drops columns rather than wrapping
-- every row. nil is the ordinary answer on a serial line, and means
-- every column is kept -- see lib/console.lua's size op on why that is
-- not guessed at.
local prog = require("prog")
local tty = prog.tty and prog.tty()
local cols = tty and tty.size()

io.write(ps.psfmt(cols) .. "\n")
