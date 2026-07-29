-- 9p server payload for the host-driven 9p test: same server the real
-- init runs, minus the repl. proc 0 (this proc) holds caps_of.wire
-- directly (granted at boot, same as the real init).

local sys = require("los.sys")
local thread = require("los.thread")
local p9 = require("ninep")
local caps_of = sys.granted()

local readreply = sys.newport()

local function wire_read()
	sys.send(caps_of.wire, { op = "read", reply = { __right = readreply } })
	return thread.recv(readreply)
end

local function wire_write(bytes)
	sys.send(caps_of.wire, { op = "write", data = bytes })
end

local root = p9.synth({
	["README"] = "this is lua-os, mounted over 9p. hello!\n",
	["uname"] = "lua-os " .. sys.stats().arch .. " uefi\n",
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
p9.serve(root, wire_read, wire_write)
