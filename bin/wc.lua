-- SPDX-License-Identifier: ISC
local function count(text)
	local lines = select(2, text:gsub("\n", ""))
	local words = select(2, text:gsub("%S+", ""))
	return lines, words, #text
end

local total_l, total_w, total_b = 0, 0, 0

local function process(name, text)
	local l, w, b = count(text)
	total_l = total_l + l
	total_w = total_w + w
	total_b = total_b + b
	print(string.format("%8d%8d%8d %s", l, w, b, name))
end

if #arg == 0 then
	process("", io.read("*a"))
else
	for _, path in ipairs(arg) do
		local f, err = io.open(path, "rb")
		if not f then
			io.stderr:write("wc: " .. path .. ": " .. err .. "\n")
			os.exit(1)
		end
		process(path, f:read("*a"))
		f:close()
	end
	if #arg > 1 then
		print(string.format("%8d%8d%8d total", total_l, total_w, total_b))
	end
end
