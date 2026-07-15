-- lua-os init (proc 0): spawn the 9p file server, then repl

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, los.firmware,
    los.firmware_revision))
print("mach-lite kernel + plan9 furniture (threads, channels, alt, 9p)")
print("")

-- 9p server proc: serves a synthetic namespace on com2.
-- it gets the serial receive right in its first message.
local _, ninesrv = los.spawn([[
	local p9 = require("ninep")
	local m = recv(los.SELF)
	local serial = m.serial.__right

	local msgs = 0
	local root = p9.synth({
		["README"] = "this is lua-os, mounted over 9p. hello!\n",
		["uname"] = "lua-os x86_64 uefi\n",
		["version"] = _VERSION .. "\n",
		["ticks"] = function(off, n)
			if off > 0 then return "" end
			return tostring(los.ticks()) .. "\n"
		end,
		["proc"] = { children = {
			["list"] = function(off, n)
				if off > 0 then return "" end
				local t = los.procs()
				local out = {}
				for i, pid in ipairs(t) do
					out[i] = tostring(pid)
				end
				return table.concat(out, " ") .. "\n"
			end,
		}},
	})

	p9.serve(root,
	    function() return recv(serial) end,
	    los.serwrite)
]])

-- hand over the serial receive right (proc 0 owns handle 2 at boot)
los.send(ninesrv, { serial = { __right = los.SERIAL } })
print("9p server listening on com2 (mount me!)")
print("")

-- repl
local function evaluate(line)
	local chunk, err = load("return " .. line, "=repl")
	if not chunk then
		chunk, err = load(line, "=repl")
	end
	return chunk, err
end

while true do
	local line = readline("> ")
	if line == nil then
		break
	end
	if #line > 0 then
		local chunk, err = evaluate(line)
		while not chunk and err and err:sub(-5) == "<eof>" do
			local more = readline(">> ")
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

print("init exiting. bye.")
