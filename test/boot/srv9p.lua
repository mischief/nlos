-- 9p server payload for the host-driven 9p test: same server the real
-- init runs, minus the repl. proc 0 keeps the serial and conio rights
-- directly (both granted at boot, same as the real init).

local sys = require("los.sys")
local thread = require("los.thread")
local p9 = require("ninep")

local root = p9.synth({
	["README"] = "this is lua-os, mounted over 9p. hello!\n",
	["uname"] = "lua-os x86_64 uefi\n",
	["echo"] = {
		data = "",
		write = function(off, data) end,
	},
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

print("9p test server ready")
p9.serve(root,
    function() return thread.recv(sys.SERIAL) end,
    function(bytes) sys.send(sys.CONIO, { op = "write", data = bytes }) end)
