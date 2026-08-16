-- task/sshd.lua, started with this payload's own tcp right, so a real
-- ssh client on the host can drive it. The guest cannot test this
-- alone: qemu's usermode network does not hairpin, so a guest dialing
-- its own listener times out.
local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local proc = require("proc")

local g = sys.granted()

if not g.tcp then
	print("sshd test: no tcp capability")
	return
end

local N = ns.current()
local src = N:readfile("/task/sshd.lua")

if not src then
	print("sshd test: no /task/sshd.lua")
	return
end

-- A fixed seed: the host key is then the same every boot, which a test
-- driving it with StrictHostKeyChecking=no does not care about and a
-- reader of this file should not mistake for entropy.
local SEED = ("lua-os sshd test seed, not a secret"):rep(2)

local pid, h = proc.spawn(src, {
	name = "sshd",
	ns = N:describe(),
	arg = {
		tcp = { __right = g.tcp },
		seed = SEED,
		args = { port = 2222 },
	},
})

if not pid then
	print("sshd test: cannot spawn: " .. tostring(h))
	return
end

-- the right was copied into the arg, so this one is ours to drop
sys.close(h)
print("sshd test server ready")

-- Nothing else to do: sshd owns the listener, and this proc parks so
-- the machine stays up for the host to drive.
thread.recv(sys.newport("sshdtest.park"))
