-- SPDX-License-Identifier: ISC

local fmt = "o" -- default octal
local files = {}
for _, a in ipairs(arg) do
	if a == "-x" then
		fmt = "x"
	elseif a == "-c" then
		fmt = "c"
	elseif a == "-o" then
		fmt = "o"
	elseif a == "-d" then
		fmt = "d"
	else
		files[#files + 1] = a
	end
end

local f = io.stdin

if #files > 0 and files[1] ~= "-" then
	local err

	f, err = io.open(files[1], "r")
	if not f then
		io.stderr:write("od: " .. files[1] .. ": " ..
		    tostring(err) .. "\n")
		os.exit(1)
	end
end

local offset = 0

while true do
	local data = f:read(16)

	if not data then
		break
	end
	local line = string.format("%07o", offset)
	for i = 1, #data, 2 do
		local b1 = data:byte(i)
		local b2 = data:byte(i + 1)
		if fmt == "o" then
			if b2 then
				line = line .. string.format(" %06o", b2 * 256 + b1)
			else
				line = line .. string.format(" %06o", b1)
			end
		elseif fmt == "x" then
			if b2 then
				line = line .. string.format("  %02x%02x", b2, b1)
			else
				line = line .. string.format("  %02x", b1)
			end
		elseif fmt == "d" then
			if b2 then
				line = line .. string.format(" %05d", b2 * 256 + b1)
			else
				line = line .. string.format(" %05d", b1)
			end
		elseif fmt == "c" then
			for j = i, math.min(i + 1, #data) do
				local c = data:byte(j)
				if c == 10 then
					line = line .. "  \\n"
				elseif c == 9 then
					line = line .. "  \\t"
				elseif c == 0 then
					line = line .. "  \\0"
				elseif c >= 32 and c < 127 then
					line = line .. "   " .. string.char(c)
				else
					line = line .. string.format(" %03o", c)
				end
			end
		end
	end
	io.write(line .. "\n")
	offset = offset + #data
end
io.write(string.format("%07o\n", offset))

if f ~= io.stdin then
	f:close()
end
