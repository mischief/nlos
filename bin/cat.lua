-- ported from the host lua/os tree, over lua's io rather than a posix
-- shim: the read loop is the only difference, and it is smaller.
-- SPDX-License-Identifier: ISC
local function cat_file(f)
	while true do
		local data = f:read(8192)

		if not data then
			break
		end
		io.write(data)
	end
end

if #arg == 0 then
	cat_file(io.stdin)
else
	for _, path in ipairs(arg) do
		local f, err = io.open(path, "r")

		if not f then
			io.stderr:write("cat: " .. path .. ": " ..
			    tostring(err) .. "\n")
			os.exit(1)
		end
		cat_file(f)
		f:close()
	end
end
