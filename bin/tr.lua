-- SPDX-License-Identifier: ISC
local getopt = require("getopt")

local flags, optind = getopt.parse(arg, "ds")

if not flags then
	io.stderr:write("tr: " .. optind .. "\n")
	os.exit(2)
end

local delete, squeeze = flags.d, flags.s
local args = table.move(arg, optind, #arg, 1, {})

-- expand ranges like a-z, character classes like [:upper:]
local function expand(s)
	-- character classes
	s = s:gsub("%[:upper:%]", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	s = s:gsub("%[:lower:%]", "abcdefghijklmnopqrstuvwxyz")
	s = s:gsub("%[:digit:%]", "0123456789")
	s = s:gsub("%[:alpha:%]", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
	s = s:gsub("%[:alnum:%]", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
	s = s:gsub("%[:space:%]", " \t\n\r\f\v")
	-- escape sequences
	s = s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r")
	-- ranges
	local result = {}
	local i = 1
	while i <= #s do
		if i + 2 <= #s and s:sub(i + 1, i + 1) == "-" then
			local from = s:byte(i)
			local to = s:byte(i + 2)
			for c = from, to do result[#result + 1] = string.char(c) end
			i = i + 3
		else
			result[#result + 1] = s:sub(i, i)
			i = i + 1
		end
	end
	return table.concat(result)
end

local set1 = expand(args[1] or "")
local set2 = expand(args[2] or "")

-- build translation/delete table
local map = {}
local squeeze_set = {}
if delete then
	for i = 1, #set1 do map[set1:sub(i, i)] = "" end
elseif set2 ~= "" then
	for i = 1, #set1 do
		local repl = set2:sub(math.min(i, #set2), math.min(i, #set2))
		map[set1:sub(i, i)] = repl
	end
end
if squeeze then
	local sset = (set2 ~= "" and not delete) and set2 or set1
	for i = 1, #sset do squeeze_set[sset:sub(i, i)] = true end
end

-- a line at a time: a byte count would make io.read fill to that count
-- before answering, and tr on a console would look hung.
local prev = nil

for data in io.stdin:lines("L") do
	local out = {}
	for i = 1, #data do
		local c = data:sub(i, i)
		local r = map[c]
		if r == "" then
			-- deleted
		else
			local ch = r or c
			if squeeze_set[ch] and ch == prev then
				-- squeezed
			else
				out[#out + 1] = ch
				prev = ch
			end
		end
	end
	io.write(table.concat(out))
end
