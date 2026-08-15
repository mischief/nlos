-- a launcher on the serial console, with the source tree mounted over
-- virtio-9p, so a host lrzsz can drive bin/rz.lua and bin/sz.lua.
--
-- Not a TAP test: the assertions are on the host, in
-- tools/zmodemtest.lua, because what is being checked is a file that
-- arrived and one that came back.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")

local caps = sys.granted()

-- com1 is the keyboard and the 9p wire both, and the wire owns those
-- bytes until the console says otherwise. Without this nothing typed
-- at the guest ever reaches a program.
sys.send(caps.cons, { op = "claim_input" })

if not caps.p9 then
	print("zmodemsh: no virtio-9p; nothing to run programs from")
	return
end

local N = ns.new()
local ok, err = N:mount("/", mnt.new(caps.p9), "mnt",
    { port = { __right = caps.p9 } })

if not ok then
	print("zmodemsh: mount: " .. tostring(err))
	return
end

-- setcurrent, not merely a mount: it is what routes require() and
-- io.open through the namespace, so a program found at /bin resolves
-- its own requires the same way.
ns.setcurrent(N)

-- dbg is deliberately absent: nothing here debugs, and a right to it
-- reaches every proc on the machine.
require("dos").start({ ns = N, cons = caps.cons },
    "lua-os. programs live in /bin.\n")

print("zmodemsh: the launcher returned")
