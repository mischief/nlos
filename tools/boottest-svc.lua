-- the service a boot test runs as, when the harness starts it that way.
--
-- A payload injected as opt/org.luaos.test replaces init.lua, so the
-- machine it tests has no services and no network. This runs instead as
-- the last entry in an injected service list: init brings the machine
-- up as a real boot does, then starts this, and this runs the payload.

-- The payload comes from fw_cfg rather than pasted in here, so no
-- quoting question arises. The key is not opt/org.luaos.test, which
-- main.c would take as a replacement for init before init ever ran.
local sys = require("los.sys")
local efi = require("los.efi")

local a = ...

-- a payload asks the kernel what it was granted. Started as a service
-- it was granted nothing directly -- lib/svc.lua hands rights over in
-- the spawn arg -- so answer with both, and leave every payload able to
-- say sys.granted() and mean it.
local caps = {}

for k, v in pairs(sys.granted()) do
	caps[k] = v
end
for k, v in pairs(type(a) == "table" and a or {}) do
	if type(v) == "table" and v.__right then
		caps[k] = v.__right
	end
end

sys.granted = function()
	local out = {}

	for k, v in pairs(caps) do
		out[k] = v
	end
	return out
end

local src = efi.fwcfg and efi.fwcfg("opt/org.luaos.testsrc")

if not src then
	print("boottest: no payload in fw_cfg")
	os.exit(1)
end
return assert(load(src, "=test"))()
