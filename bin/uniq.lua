-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local flags, optind = getopt.parse(arg, "cdu")

if not flags then
	io.stderr:write("uniq: " .. optind .. "\n")
	os.exit(2)
end

local count_mode, dup_only, uniq_only = flags.c, flags.d, flags.u
local files = table.move(arg, optind, #arg, 1, {})

local f = io.stdin

if #files > 0 and files[1] ~= "-" then
	local err

	f, err = io.open(files[1], "r")
	if not f then
		io.stderr:write("uniq: " .. files[1] .. ": " ..
		    tostring(err) .. "\n")
		os.exit(1)
	end
end

local content = f:read("a")

if f ~= io.stdin then
	f:close()
end

local function output(line, cnt)
	if dup_only and cnt < 2 then
		return
	end
	if uniq_only and cnt > 1 then
		return
	end
	if count_mode then
		io.write(string.format("%7d %s\n", cnt, line))
	else
		io.write(line .. "\n")
	end
end

local prev = nil
local cnt = 0
for line in content:gmatch("([^\n]*)\n?") do
	if line == "" and content:sub(-1) ~= "\n" and prev ~= nil then
		break
	end
	if line == prev then
		cnt = cnt + 1
	else
		if prev ~= nil then
			output(prev, cnt)
		end
		prev = line
		cnt = 1
	end
end
if prev ~= nil then
	output(prev, cnt)
end
