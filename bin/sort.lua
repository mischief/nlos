-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local flags, optind = getopt.parse(arg, "nrk:")

if not flags then
	io.stderr:write("sort: " .. optind .. "\n")
	os.exit(2)
end

local numeric, reverse = flags.n, flags.r
local key = flags.k and tonumber(flags.k)
local files = table.move(arg, optind, #arg, 1, {})

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
