-- lua-os init: banner + repl

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, los.firmware,
    los.firmware_revision))
print("lua-os repl. ctrl-d on empty line exits, los.reset('shutdown') powers off.")
print("")

local function evaluate(line)
	-- expression first, statement second (standard repl trick)
	local chunk, err = load("return " .. line, "=repl")
	if not chunk then
		chunk, err = load(line, "=repl")
	end
	return chunk, err
end

local function incomplete(err)
	return err and err:sub(-5) == "<eof>"
end

while true do
	io.write("> ")
	local line = los.readline()
	if line == nil then
		break
	end
	if #line > 0 then
		local chunk, err = evaluate(line)
		while not chunk and incomplete(err) do
			io.write(">> ")
			local more = los.readline()
			if more == nil then
				break
			end
			line = line .. "\n" .. more
			chunk, err = load(line, "=repl")
		end
		if chunk then
			local res = table.pack(pcall(chunk))
			if res[1] then
				if res.n > 1 then
					print(table.unpack(res, 2, res.n))
				end
			else
				print("error: " .. tostring(res[2]))
			end
		else
			print(err)
		end
	end
end

print("repl done. bye.")
