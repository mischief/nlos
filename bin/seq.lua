-- ported from the host lua/os tree, UNCHANGED except this line
-- SPDX-License-Identifier: ISC
local unistd = require("posix.unistd")

local first, incr, last
if #arg == 1 then
	first, incr, last = 1, 1, tonumber(arg[1])
elseif #arg == 2 then
	first, incr, last = tonumber(arg[1]), 1, tonumber(arg[2])
elseif #arg >= 3 then
	first, incr, last = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3])
end

if not (first and incr and last) then
	unistd.write(2, "seq: invalid argument\n")
	os.exit(1)
end

local i = first
while (incr > 0 and i <= last) or (incr < 0 and i >= last) do
	unistd.write(1, tostring(i) .. "\n")
	i = i + incr
end
