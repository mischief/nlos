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

local function head(f, name, show_header)
	if show_header then
		print("==> " .. name .. " <==")
	end
	local i = 0
	for line in f:lines() do
		io.write(line .. "\n")
		i = i + 1
		if i >= n then
			break
		end
	end
end

if #files == 0 then
	head(io.stdin, "", false)
else
	for _, path in ipairs(files) do
		local f, err = io.open(path)
		if not f then
			io.stderr:write("head: " .. path .. ": " .. err .. "\n")
			os.exit(1)
		end
		head(f, path, #files > 1)
		f:close()
	end
end
