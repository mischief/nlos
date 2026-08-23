-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local suppress = {}
local optind = 1

for opt, optarg, oi in getopt.opts(arg, "123") do
	if opt == "1" then suppress[1] = true
	elseif opt == "2" then suppress[2] = true
	elseif opt == "3" then suppress[3] = true
	end
	optind = oi
end

if #arg - optind + 1 ~= 2 then
	io.stderr:write("usage: comm [-123] file1 file2\n")
	os.exit(1)
end

local function open_file(path)
	if path == "-" then
		return io.stdin
	end

	local f, err = io.open(path, "r")

	if not f then
		io.stderr:write("comm: " .. path .. ": " ..
		    tostring(err) .. "\n")
		os.exit(1)
	end
	return f
end

local f1 = open_file(arg[optind])
local f2 = open_file(arg[optind + 1])

local line1 = f1:read("l")
local line2 = f2:read("l")

local col2 = suppress[1] and "" or "\t"
local col3 = (suppress[1] and "" or "\t") .. (suppress[2] and "" or "\t")

while line1 or line2 do
	if line1 and (not line2 or line1 < line2) then
		if not suppress[1] then io.write(line1 .. "\n") end
		line1 = f1:read("l")
	elseif line2 and (not line1 or line2 < line1) then
		if not suppress[2] then io.write(col2 .. line2 .. "\n") end
		line2 = f2:read("l")
	else
		if not suppress[3] then io.write(col3 .. line1 .. "\n") end
		line1 = f1:read("l")
		line2 = f2:read("l")
	end
end
