-- heap: what this program costs, from inside it.
--
-- The floor a cli program starts from, which is the lua state plus
-- whatever lib/prog.lua brings with it. Useful when the question is
-- what a program costs rather than what the machine holds: sys.meminfo
-- from outside cannot separate a program that has run from one that has
-- only started.

local unistd = require("posix.unistd")

collectgarbage()
collectgarbage()

local t = {}

for k in pairs(package.loaded) do
	t[#t + 1] = k
end
table.sort(t)

unistd.write(1, string.format("lua=%d modules=%d\n%s\n",
    math.floor(collectgarbage("count") * 1024), #t,
    table.concat(t, " ")))
