-- ported from the host lua/os tree, UNCHANGED except this line
-- SPDX-License-Identifier: ISC
local unistd = require("posix.unistd")
local fcntl = require("posix.fcntl")

local function cat_fd(fd)
	while true do
		local data, err = unistd.read(fd, 8192)
		if not data or data == "" then
			break
		end
		unistd.write(1, data)
	end
end

if #arg == 0 then
	cat_fd(0)
else
	for _, path in ipairs(arg) do
		local fd, err = fcntl.open(path, fcntl.O_RDONLY)
		if not fd then
			io.stderr:write("cat: " .. path .. ": " .. err .. "\n")
			os.exit(1)
		end
		cat_fd(fd)
		unistd.close(fd)
	end
end
