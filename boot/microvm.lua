-- the microvm boot payload of last resort: what proc 0 runs when no
-- fw_cfg payload was injected (src/platform/microvm/main.c). It is
-- embedded in the image at build time, so a machine with no fw_cfg
-- file service at all still boots to something that speaks.
--
-- OpenBSD vmd is the reason it exists. Its fw_cfg (usr.sbin/vmd/
-- fw_cfg.c) serves a fixed set -- an e820 map and a bootorder string --
-- and has no way to name a host file from vm.conf, so the mechanism
-- every microvm test uses to start code is simply not available there.
-- Without a payload of its own the kernel reached kernel_run() with no
-- proc and reset.
--
-- It deliberately asks for nothing but the console: no virtio, no
-- network, no mount. Those are the parts a new machine has not earned
-- yet, and a payload that blocks in a driver waiting for a device that
-- is not there says nothing on the serial line about why.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(3)

local caps = sys.granted()

tap.ok(caps.cons ~= nil, "the console capability was granted")

require("stdout").set(caps.cons)

-- the scheduler is the one thing worth proving beyond "we printed":
-- a child running at all means proc creation, message copy and the
-- run loop are live, which is everything the kernel owes a payload.
local myright = sys.sendright(0)

local child = sys.spawn([[
	local sys = require("los.sys")
	local parent = (...).__right
	sys.send(parent, "hello from " .. sys.self())
]], { arg = { __right = myright } })

tap.ok(child ~= nil, "spawned a child")

local msg

while not msg do
	local ok, m = sys.tryrecv(0)

	if ok then
		msg = m
	else
		sys.yield()
	end
end

tap.ok(msg:match("^hello from %d+$") ~= nil,
    "the child ran and its message came back: " .. msg)

tap.done()
