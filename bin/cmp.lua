-- SPDX-License-Identifier: ISC

if #arg < 2 then
	io.stderr:write("cmp: missing operand\n")
	os.exit(2)
end

local f1 = io.open(arg[1], "r")
local f2 = io.open(arg[2], "r")
if not f1 or not f2 then
	io.stderr:write("cmp: cannot open file\n")
	os.exit(2)
end

local byte = 0
local line = 1
while true do
	local c1 = f1:read(1)
	local c2 = f2:read(1)
	if (not c1 or c1 == "") and (not c2 or c2 == "") then
		break
	end
	byte = byte + 1
	if c1 ~= c2 then
		if not c1 or c1 == "" then
			io.stderr:write("cmp: EOF on " .. arg[1] .. "\n")
		elseif not c2 or c2 == "" then
			io.stderr:write("cmp: EOF on " .. arg[2] .. "\n")
		else
			io.write(string.format("%s %s differ: byte %d, line %d\n", arg[1], arg[2], byte, line))
		end
		f1:close()
		f2:close()
		os.exit(1)
	end
	if c1 == "\n" then
		line = line + 1
	end
end

f1:close()
f2:close()
os.exit(0)
