-- SPDX-License-Identifier: ISC

if #arg == 0 then
	os.exit(0)
end

local fmt = arg[1]
local ai = 2 -- argument index

-- process escape sequences in format
local function unescape(s)
	s = s:gsub("\\n", "\n")
	s = s:gsub("\\t", "\t")
	s = s:gsub("\\r", "\r")
	s = s:gsub("\\0(%d+)", function(o)
		return string.char(tonumber(o, 8))
	end)
	s = s:gsub("\\\\", "\\")
	return s
end

fmt = unescape(fmt)

-- expand format specifiers with arguments
local out = fmt:gsub("(%%[-#+ 0]*%d*%.?%d*[diouxXeEfgGcs%%])", function(spec)
	if spec == "%%" then
		return "%"
	end
	local conv = spec:sub(-1)
	local a = arg[ai] or ""
	ai = ai + 1
	if conv == "d" or conv == "i" or conv == "o" or conv == "u" or conv == "x" or conv == "X" then
		return string.format(spec, tonumber(a) or 0)
	elseif conv == "e" or conv == "E" or conv == "f" or conv == "g" or conv == "G" then
		return string.format(spec, tonumber(a) or 0)
	elseif conv == "c" then
		return a:sub(1, 1)
	elseif conv == "s" then
		return string.format(spec, a)
	end
	return spec
end)

io.write(out)
