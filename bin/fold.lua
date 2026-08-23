-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local width = 80
local break_spaces = false

local optind = 1
for opt, optarg, oi in getopt.opts(arg, "bsw:") do
	if opt == "w" then
		width = tonumber(optarg) or 80
	elseif opt == "s" then
		break_spaces = true
	end
	optind = oi
end

local function fold_line(line)
	if #line <= width then
		io.write(line .. "\n")
		return
	end
	local pos = 1
	while pos <= #line do
		if pos + width - 1 >= #line then
			io.write(line:sub(pos) .. "\n")
			break
		end
		local chunk = line:sub(pos, pos + width - 1)
		if break_spaces then
			local bp = chunk:match(".*()%s")
			if bp and bp > 1 then
				io.write(line:sub(pos, pos + bp - 1) .. "\n")
				pos = pos + bp
			else
				io.write(chunk .. "\n")
				pos = pos + width
			end
		else
			io.write(chunk .. "\n")
			pos = pos + width
		end
	end
end

local function process(f)
	for line in f:lines("l") do
		fold_line(line)
	end
end

if optind > #arg then
	process(io.stdin)
else
	for i = optind, #arg do
		if arg[i] == "-" then
			process(io.stdin)
		else
			local f, err = io.open(arg[i], "r")

			if not f then
				io.stderr:write("fold: " .. arg[i] .. ": " ..
				    tostring(err) .. "\n")
				os.exit(1)
			end
			process(f)
			f:close()
		end
	end
end
