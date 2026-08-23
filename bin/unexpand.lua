-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local tabstop = 8
local all = false

local optind = 1
for opt, optarg, oi in getopt.opts(arg, "at:") do
	if opt == "t" then
		tabstop = tonumber(optarg) or 8
		all = true
	elseif opt == "a" then
		all = true
	end
	optind = oi
end

local function unexpand_line(line)
	local out = {}
	local col = 0
	local i = 1
	local leading = true
	while i <= #line do
		if line:sub(i, i) == " " and (leading or all) then
			local j = i
			while j <= #line and line:sub(j, j) == " " do
				j = j + 1
			end
			local end_col = col + (j - i)
			local pos = col
			while pos < end_col do
				local next_stop = tabstop - (pos % tabstop)
				if pos + next_stop <= end_col then
					out[#out + 1] = "\t"
					pos = pos + next_stop
				else
					out[#out + 1] = string.rep(" ", end_col - pos)
					pos = end_col
				end
			end
			col = end_col
			i = j
		else
			if line:sub(i, i) ~= " " then leading = false end
			out[#out + 1] = line:sub(i, i)
			col = col + 1
			i = i + 1
		end
	end
	return table.concat(out)
end

local function process(f)
	for line in f:lines("l") do
		io.write(unexpand_line(line) .. "\n")
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
				io.stderr:write("unexpand: " .. arg[i] .. ": " ..
				    tostring(err) .. "\n")
				os.exit(1)
			end
			process(f)
			f:close()
		end
	end
end
