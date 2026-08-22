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

-- what to play through and how loudly, remembered across boots.
-- `key value` a line; a file holding a bare sink name is one written
-- before there was anything else to say.
M.CONF = "/config/audio"

local function settings()
	local f = io.open(M.CONF, "r")
	local out = { sink = "auto", volume = 100 }

	if not f then
		return out
	end

	for line in f:lines() do
		local k, v = line:match("^%s*(%S+)%s+(%S+)%s*$")

		if k == "sink" then
			out.sink = v:lower()
		elseif k == "volume" then
			out.volume = tonumber(v) or out.volume
		elseif not k then
			local bare = line:lower():gsub("%s", "")

			if bare == "usb" or bare == "i2s" then
				out.sink = bare
			end
		end
	end
	f:close()
	if out.sink ~= "usb" and out.sink ~= "i2s" then
		out.sink = "auto"
	end
	out.volume = math.max(0, math.min(100, math.floor(out.volume)))
	return out
end

local function save(t)
	local f, why = io.open(M.CONF, "w")

	if not f then
		return nil, tostring(why)
	end
	f:write("sink ", t.sink, "\n", "volume ", t.volume, "\n")
	f:close()
	return true
end

function M.sink()
	return settings().sink
end

-- setsink(name) -> true, or nil and why. /config is a mount rather
-- than a capability, so a session without it says so here.
function M.setsink(name)
	if name ~= "usb" and name ~= "i2s" and name ~= "auto" then
		return nil, "no such sink"
	end
	-- pinning the sink to a port with nothing on it is a machine that
	-- plays nowhere until somebody remembers this was set. auto still
	-- reaches the port, and reaches it when a card is there.
	if name == "usb" and not M.usbaudio() then
		return nil, "no usb sound card"
	end

	local t = settings()

	t.sink = name
	return save(t)
end

-- 0 to 100. Applied to the samples: see src/pcm_native.c for why
-- neither device applies it itself.
function M.volume()
	return settings().volume
end

function M.setvolume(pct)
	pct = tonumber(pct)
	if not pct then
		return nil, "volume is a number"
	end

	local t = settings()

	t.volume = math.max(0, math.min(100, math.floor(pct)))
	return save(t)
end

-- the next stop up from where the volume is, wrapping at the top. A
-- value set from somewhere else rounds onto the steps rather than
-- carrying its offset around for ever.
M.VOLSTEP = 20

function M.nextvolume(v)
	local up = ((tonumber(v) or 0) // M.VOLSTEP) * M.VOLSTEP + M.VOLSTEP

	if up > 100 then
		return 0
	end
	return up
end

-- what a percentage does to a sample. Squared, because loudness is not
-- linear in amplitude: halfway down the scale should sound halfway
-- down, and linear scaling there is barely quieter.
local function factor(pct)
	return math.floor(256 * (pct / 100) * (pct / 100) + 0.5)
end

local native = nil

do
	local ok, m = pcall(require, "pcm.native")

	native = ok and m or nil
end

-- the same thing in lua, for a machine without the module. Slow on
-- purpose rather than absent: a volume that silently did nothing is
-- worse than one that costs.
local function luagain(s, q)
	if q == 256 then
		return s
	end

	local out = {}
	local sp, sb, sc = string.pack, string.byte, table.concat

	for i = 1, #s - 1, 2 do
		local lo, hi = sb(s, i, i + 1)
		local v = lo | (hi << 8)

		if v >= 32768 then
			v = v - 65536
		end
		v = (v * q) // 256
		if v > 32767 then
			v = 32767
		elseif v < -32768 then
			v = -32768
		end
		out[#out + 1] = sp("<i2", v)
	end
	return sc(out) .. (#s % 2 == 1 and s:sub(#s) or "")
end

function M.gain(s, q)
	if native then
		return native.gain(s, q)
	end
	return luagain(s, q)
end

-- is there a sound card on the port now?
--
-- Only what is already visible: seeing anything at all means the host
-- controller is running, and starting it is what takes the console on
-- a board where that port is the console. So this answers no on a
-- machine that has never looked, which is the safe way to be wrong.
function M.usbaudio()
	if not (sys.usbhave and sys.usbhave() and sys.usbdesc) then
		return false
	end

	local desc = sys.usbdesc()

	if not desc then
		return false
	end

	local cfg = require("usb").parse(desc)

	if not cfg then
		return false
	end
	for _, itf in ipairs(cfg.interfaces or {}) do
		if itf.class == require("usb").AUDIO then
			return true
		end
	end
	return false
end

-- may we look for a card, and what it would cost.
--
-- Looking means starting the host, which cannot be undone. Where the
-- port is the console that spends it -- but only if a host is talking
-- on it: with nothing attached, the console over that port is already
-- reaching nobody, so looking costs nothing that works.
function M.canprobe()
	if not (sys.usbhave and sys.usbhave()) then
		return false, "no usb controller"
	end
	if M.usbaudio() then
		return false, "a card is already there"
	end
	if sys.usbconsole and sys.usbconsole() and
	    sys.usbattached and sys.usbattached() then
		return false, "the console is on that port"
	end
	return true
end

-- look, once. Answers whether a sound card turned up.
function M.probe()
	local ok, why = M.canprobe()

	if not ok then
		return false, why
	end
	if not sys.usbhost() then
		return false, "the controller would not start"
	end

	local until_ = sys.uptime_ms() + SETTLE_MS

	repeat
		if M.usbaudio() then
			return true
		end
		thread.sleep(100)
	until sys.uptime_ms() >= until_
	return false, "nothing on the port"
end

-- what this machine could play through now. usbhave, never usbhost:
-- the latter starts the controller, and where the console is that port
-- the console goes with it. The port is listed only with a card on it,
-- since choosing it otherwise buys silence and sometimes the console.
function M.sinks()
	local out = {}

	if sys.i2shave and sys.i2shave() then
		out[#out + 1] = "i2s"
	end
	if M.usbaudio() then
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
			return M.leveled(d)
		end
		why = why or no
	end
	return nil, why or "no audio device"
end

-- the device with the volume in front of it. The setting is read here
-- rather than per write -- a file read costs more than the scaling on
-- this hardware -- so setgain is how a program changes it mid-track.
function M.leveled(dev, pct)
	local q = factor(pct or M.volume())
	local raw = dev.write

	dev.write = function(s)
		if q == 256 then
			return raw(s)
		end

		local took = raw(M.gain(s, q))

		-- the caller resumes from the unscaled bytes, so a take
		-- that stops mid-sample would put every later pair one
		-- byte out. Give the half-sample back.
		if took and took % 2 == 1 then
			return took - 1
		end
		return took
	end
	dev.setgain = function(n)
		q = factor(math.max(0, math.min(100, tonumber(n) or 100)))
	end
	return dev
end

return M
