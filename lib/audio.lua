-- audio: where the samples go, whichever this machine has.
--
-- Two devices answer the same four calls. A sound card on the USB port
-- has to be found, asked what it can play and claimed; an amplifier
-- wired to the board has none of that and takes a rate. A caller
-- wanting neither in particular says open(rate, channels, width).

local sys = require("los.sys")
local thread = require("los.thread")

local M = {}

-- how long to wait for a device to enumerate. A card is not there the
-- instant the port is powered.
local SETTLE_MS = 3000

local function usbopen(rate, channels, width)
	if not sys.usbhost or not sys.usbhost() then
		return nil, "no usb host"
	end

	local usb = require("usb")
	local uac = require("uac")
	local desc
	local until_ = sys.uptime_ms() + SETTLE_MS

	repeat
		desc = sys.usbdesc()
		if desc then
			break
		end
		thread.sleep(100)
	until sys.uptime_ms() >= until_

	if not desc then
		return nil, "nothing on the usb port"
	end

	local cfg, why = usb.parse(desc)

	if not cfg then
		return nil, why
	end

	local s, no = uac.playback(cfg, { rate = rate, channels = channels,
	    width = width })

	if not s then
		return nil, no
	end

	local packet = uac.packet(s, rate)

	if not packet then
		return nil, "the device cannot carry that rate"
	end
	if not sys.usbplay(s.interface, s.alt, s.endpoint.address, packet,
	    rate) then
		return nil, "the device refused to play"
	end
	return {
		kind = "usb",
		write = sys.usbwrite,
		stop = sys.usbstop,
		underruns = sys.usbunderruns,
	}
end

local function i2sopen(rate, channels)
	if not sys.i2shave or not sys.i2shave() then
		return nil, "no amplifier"
	end
	if not sys.i2splay(rate, channels) then
		return nil, "cannot play at that rate"
	end
	return {
		kind = "i2s",
		write = sys.i2swrite,
		stop = sys.i2sstop,
		underruns = sys.i2sunderruns,
	}
end

-- what to play through, remembered across boots. "usb", "i2s", or
-- "auto"; anything else, or no file at all, is auto.
M.CONF = "/config/audio"

function M.sink()
	local f = io.open(M.CONF, "r")

	if not f then
		return "auto"
	end

	local s = (f:read("l") or ""):lower():gsub("%s", "")

	f:close()
	if s == "usb" or s == "i2s" then
		return s
	end
	return "auto"
end

-- setsink(name) -> true, or nil and why. /config is a mount rather
-- than a capability, so a session without it says so here.
function M.setsink(name)
	if name ~= "usb" and name ~= "i2s" and name ~= "auto" then
		return nil, "no such sink"
	end

	local f, why = io.open(M.CONF, "w")

	if not f then
		return nil, tostring(why)
	end
	f:write(name, "\n")
	f:close()
	return true
end

-- what this machine could play through, whether or not it would.
--
-- usbhave, never usbhost: the latter starts the controller, and on a
-- board whose console is that port the console is gone until the next
-- boot. Asking what the machine can do must not change what it is
-- doing.
function M.sinks()
	local out = {}

	if sys.i2shave and sys.i2shave() then
		out[#out + 1] = "i2s"
	end
	if sys.usbhave and sys.usbhave() then
		out[#out + 1] = "usb"
	end
	return out
end

-- open(rate, channels, width) -> device, or nil and why
--
-- auto prefers a card on the usb port, which is a thing somebody
-- plugged in on purpose. The exception is a board where that port is
-- also the console: probing it there takes the console until the next
-- boot, so auto leaves it alone and the setting is how you ask.
function M.open(rate, channels, width)
	local want = M.sink()
	local costly = sys.usbconsole and sys.usbconsole()
	local order

	if want == "usb" then
		order = { usbopen }
	elseif want == "i2s" then
		order = { i2sopen }
	elseif costly then
		-- and not as a fallback either: falling back to usb here
		-- would take the console on the way past, which is not a
		-- thing to do because the amplifier was busy.
		order = { i2sopen }
	else
		order = { usbopen, i2sopen }
	end

	local why

	for _, fn in ipairs(order) do
		local d, no = fn(rate, channels, width)

		if d then
			return d
		end
		why = why or no
	end
	return nil, why or "no audio device"
end

return M
