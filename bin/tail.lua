-- SPDX-License-Identifier: ISC
local n = 10
local files = {}
for _, a in ipairs(arg) do
	if a:match("^%-(%d+)$") then
		n = tonumber(a:match("^%-(%d+)$"))
	else
		files[#files + 1] = a
	end
end

local function tail(f, name, show_header)
	if show_header then
		print("==> " .. name .. " <==")
	end
	local buf = {}
	for line in f:lines() do
		buf[#buf + 1] = line
		if #buf > n then
			table.remove(buf, 1)
		end
	end
	for _, line in ipairs(buf) do
		io.write(line .. "\n")
	end
end

if #files == 0 then
	tail(io.stdin, "", false)
else
	for _, path in ipairs(files) do
		local f, err = io.open(path)
		if not f then
			io.stderr:write("tail: " .. path .. ": " .. err .. "\n")
			os.exit(1)
		end
		tail(f, path, #files > 1)
		f:close()
	end
end
