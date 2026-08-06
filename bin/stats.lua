-- stats: what the machine is holding.
--
-- The repl has this as a bare word; a dos shell has no bare-word
-- globals, so the same formatter needs a program in front of it. See
-- bin/ps.lua.
--
-- One line, and no terminal width is asked for: unlike ps and ports
-- there are no columns to drop, and what would not fit simply wraps.
--
-- No capability is required and none is granted: sys.stats is an
-- observation of the machine rather than authority over it.

local unistd = require("posix.unistd")

local ok, ps = pcall(require, "ps")

if not ok then
	unistd.write(2, "stats: cannot load lib/ps.lua: " .. tostring(ps) .. "\n")
	os.exit(1)
end

unistd.write(1, tostring(ps.stats) .. "\n")
