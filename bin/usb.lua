-- usb: drive the port as a host, and report what is on it.
--
-- Where the console shares the port's pins it goes away here, so run
-- logcast first if you want to read the descriptors somewhere else.

local sys = require("los.sys")
local thread = require("los.thread")
local usb = require("usb")
local uac = require("uac")
local unistd = require("posix.unistd")

local function say(s)
	unistd.write(1, s .. "\n")
end

-- what enumerated, once it has. The raw descriptor is in the log either
-- way, which is what to read when this cannot make sense of it.
local function report(desc)
	local cfg, why = usb.parse(desc)

	if not cfg then
		say("usb: " .. why)
		return
	end
	for _, line in ipairs(uac.describe(cfg)) do
		say("usb: " .. line)
	end
end

if not sys.usbhost() then
	unistd.write(2, "usb: this machine has no host controller\n")
	os.exit(1)
end

say("usb: host up. plug something in")

local tick = sys.newport("usb.tick")
local seen

while true do
	local desc = sys.usbdesc()

	if desc and desc ~= seen then
		seen = desc
		report(desc)
	elseif not desc and seen then
		seen = nil
		say("usb: gone")
	end
	thread.recvtimeout(tick, 300)
end
