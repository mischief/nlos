-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local tabstops = { 8 }

local optind = 1
for opt, optarg, oi in getopt.opts(arg, "t:") do
	if opt == "t" then
		tabstops = {}
		for n in optarg:gmatch("%d+") do
			tabstops[#tabstops + 1] = tonumber(n)
		end
		if #tabstops == 0 then tabstops = { 8 } end
	end
	optind = oi
end

local function next_tab(col)
	if #tabstops == 1 then
		local ts = tabstops[1]
		return ts - (col % ts)
	end
	for _, stop in ipairs(tabstops) do
		if stop > col then return stop - col end
	end
	return 1
end

-- a line at a time, so the column count starts where the line does. A
-- chunk at a time restarted it every 4096 bytes, and a tab past that
-- expanded to the wrong stop.
local function process(f)
	for line in f:lines("L") do
		local out, col = {}, 0

		for i = 1, #line do
			local c = line:sub(i, i)

			if c == "\t" then
				local spaces = next_tab(col)

				out[#out + 1] = string.rep(" ", spaces)
				col = col + spaces
			elseif c == "\n" then
				out[#out + 1] = c
				col = 0
			else
				out[#out + 1] = c
				col = col + 1
			end
		end
		io.write(table.concat(out))
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
				io.stderr:write("expand: " .. arg[i] .. ": " ..
				    tostring(err) .. "\n")
				os.exit(1)
			end
			process(f)
			f:close()
		end
	end
end
