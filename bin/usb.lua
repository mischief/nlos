-- usb: drive the port as a host, and report what is on it.
--
-- Where the console shares the port's pins it goes away here, so run
-- logcast first if you want to read the descriptors somewhere else.

local sys = require("los.sys")
local thread = require("los.thread")
local unistd = require("posix.unistd")

if not sys.usbhost() then
	unistd.write(2, "usb: this machine has no host controller\n")
	os.exit(1)
end

unistd.write(1, "usb: host up. plug something in; watch the log\n")

local tick = sys.newport("usb.tick")
local from = select(2, sys.dmesg(-1, 1))

while true do
	local text, next = sys.dmesg(from)

	if text ~= "" then
		for line in text:gmatch("[^\n]+") do
			if line:find("usb:", 1, true) then
				unistd.write(1, line .. "\n")
			end
		end
		from = next
	else
		thread.recvtimeout(tick, 200)
	end
end
