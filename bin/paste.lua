-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local delimiters = "\t"
local serial = false
local optind = 1

for opt, optarg, oi in getopt.opts(arg, "sd:") do
	if opt == "d" then
		delimiters = optarg
	elseif opt == "s" then
		serial = true
	end
	optind = oi
end

local files = {}

for i = optind, #arg do
	if arg[i] == "-" then
		files[#files + 1] = { h = io.stdin, done = false }
	else
		local f, err = io.open(arg[i], "r")

		if not f then
			io.stderr:write("paste: " .. arg[i] .. ": " ..
			    tostring(err) .. "\n")
			os.exit(1)
		end
		files[#files + 1] = { h = f, done = false }
	end
end
if #files == 0 then
	files[1] = { h = io.stdin, done = false }
end

local function get_delim(n)
	if #delimiters == 0 then return "" end
	local idx = ((n - 1) % #delimiters) + 1
	local c = delimiters:sub(idx, idx)
	if c == "\\" and idx < #delimiters then
		local nc = delimiters:sub(idx + 1, idx + 1)
		if nc == "n" then return "\n"
		elseif nc == "t" then return "\t"
		elseif nc == "\\" then return "\\"
		elseif nc == "0" then return ""
		end
	end
	return c
end

if serial then
	for _, f in ipairs(files) do
		local first = true
		local di = 1
		while true do
			local line = f.h:read("l")
			if not line then break end
			if not first then
				io.write(get_delim(di))
				di = di + 1
			end
			io.write(line)
			first = false
		end
		io.write("\n")
		if f.h ~= io.stdin then f.h:close() end
	end
else
	while true do
		local all_done = true
		local out = {}
		for i, f in ipairs(files) do
			if i > 1 then out[#out + 1] = get_delim(i - 1) end
			if not f.done then
				local line = f.h:read("l")
				if line then
					out[#out + 1] = line
					all_done = false
				else
					f.done = true
					out[#out + 1] = ""
				end
			else
				out[#out + 1] = ""
			end
		end
		if all_done then break end
		io.write(table.concat(out) .. "\n")
	end
end
