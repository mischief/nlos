-- SPDX-License-Identifier: ISC

local numeric = false
local reverse = false
local key = nil
local files = {}

local i = 1
while i <= #arg do
	local a = arg[i]
	if a == "-n" then
		numeric = true
	elseif a == "-r" then
		reverse = true
	elseif a == "-k" then
		i = i + 1
		key = tonumber(arg[i])
	elseif a == "-nr" or a == "-rn" then
		numeric = true
		reverse = true
	elseif a:sub(1, 1) == "-" then
		for j = 2, #a do
			local c = a:sub(j, j)
			if c == "n" then
				numeric = true
			elseif c == "r" then
				reverse = true
			end
		end
	else
		files[#files + 1] = a
	end
	i = i + 1
end

-- read input
local content

if #files == 0 then
	content = io.read("a")
else
	local parts = {}

	for _, name in ipairs(files) do
		local f, err = io.open(name, "r")

		if not f then
			io.stderr:write("sort: " .. name .. ": " ..
			    tostring(err) .. "\n")
			os.exit(1)
		end
		parts[#parts + 1] = f:read("a")
		f:close()
	end
	content = table.concat(parts)
end

-- split into lines
local lines = {}
for line in content:gmatch("([^\n]*)\n?") do
	if line ~= "" or content:sub(-1) == "\n" then
		lines[#lines + 1] = line
	end
end
-- remove trailing empty line if input ended with \n
if #lines > 0 and lines[#lines] == "" then
	table.remove(lines)
end

-- extract sort key from a line
local function get_key(line)
	if key then
		local k = 0
		for field in line:gmatch("%S+") do
			k = k + 1
			if k == key then
				return field
			end
		end
		return ""
	end
	return line
end

-- sort
table.sort(lines, function(a, b)
	local ka, kb = get_key(a), get_key(b)
	if numeric then
		ka, kb = tonumber(ka) or 0, tonumber(kb) or 0
	end
	if reverse then
		return ka > kb
	end
	return ka < kb
end)

-- output
for _, line in ipairs(lines) do
	io.write(line .. "\n")
end
