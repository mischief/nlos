-- ports: where messages are going, and what is being refused.
--
-- The repl has this as a bare word; a dos shell has no bare-word
-- globals, so the same formatter needs a program in front of it -- and
-- a session over ssh or a browser reaches /bin, not the repl's _ENV.
-- bin/ps.lua says the same about itself.
--
-- No capability is required and none is granted: sys.ports is an
-- observation of the machine rather than authority over it.

local ok, ps = pcall(require, "ps")

if not ok then
	io.stderr:write("ports: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

-- the terminal's width, so the table drops columns rather than wrapping
-- every row. nil on a serial line, and means every column is kept.
local prog = require("prog")
local tty = prog.tty and prog.tty()
local cols = tty and tty.size()

io.write(ps.portsfmt(cols) .. "\n")
