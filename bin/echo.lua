-- echo: write the arguments, separated by spaces, and a newline.
--
-- A program rather than a builtin, which is the rule lib/dos.lua sets
-- out: a builtin is for what changes the launcher's own state, and this
-- changes nothing. It also means echo composes -- `echo hi > /tmp/x`
-- and `echo hi ! cat` work through the ordinary ABI -- where a builtin
-- is refused in a pipeline and never sees a redirection at all.
--
-- -n omits the newline, as everywhere else. Nothing else is
-- interpreted: no -e, no backslash escapes. The shell already has
-- quotes, and a program that reinvents them disagrees with them.

local unistd = require("posix.unistd")

local out = {}
local nl = true
local from = 1

if arg[1] == "-n" then
	nl = false
	from = 2
end

for i = from, #arg do
	out[#out + 1] = arg[i]
end

unistd.write(1, table.concat(out, " ") .. (nl and "\n" or ""))
