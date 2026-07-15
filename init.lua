-- lua-os init (proc 0): spawn the 9p file server, then repl

local sys = require("los.sys")
local efi = require("los.efi")
local thread = require("los.thread")

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, efi.firmware,
    efi.firmware_revision))
print("mach-lite kernel + plan9 furniture (threads, channels, alt, 9p)")
print("")

-- 9p server proc: serves a synthetic namespace on com2.
-- it gets the serial receive right in its first message.
local _, ninesrv = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local p9 = require("ninep")
	local m = thread.recv(sys.SELF)
	local serial = m.serial.__right

	local root = p9.synth({
		["README"] = "this is lua-os, mounted over 9p. hello!\n",
		["uname"] = "lua-os x86_64 uefi\n",
		["version"] = _VERSION .. "\n",
		["ticks"] = function(off, n)
			if off > 0 then return "" end
			return tostring(sys.ticks()) .. "\n"
		end,
		["proc"] = { children = {
			["list"] = function(off, n)
				if off > 0 then return "" end
				local t = sys.procs()
				local out = {}
				for i, pid in ipairs(t) do
					out[i] = tostring(pid)
				end
				return table.concat(out, " ") .. "\n"
			end,
		}},
	})

	p9.serve(root,
	    function() return thread.recv(serial) end,
	    sys.serwrite)
]])

-- hand over the serial receive right (proc 0 owns handle 2 at boot)
sys.send(ninesrv, { serial = { __right = sys.SERIAL } })
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
	local line = thread.readline("> ")
	if line == nil then
		break
	end
	if #line > 0 then
		local chunk, err = evaluate(line)
		while not chunk and err and err:sub(-5) == "<eof>" do
			local more = thread.readline(">> ")
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
