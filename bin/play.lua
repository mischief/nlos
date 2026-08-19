-- play: a wav file, out of the usb audio device on the port.
--
--	play /sd/music/song.wav
--
-- The device decides what can be played, so a file whose rate it does
-- not list is refused rather than played at the wrong speed.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local usb = require("usb")
local uac = require("uac")
local wav = require("wav")
local unistd = require("posix.unistd")

local CHUNK = 4096

local function die(s)
	unistd.write(2, "play: " .. s .. "\n")
	os.exit(1)
end

local rate, path

local i = 1

while i <= #arg do
	if arg[i] == "-r" then
		i = i + 1
		rate = tonumber(arg[i]) or die("-r wants a rate")
	else
		path = arg[i]
	end
	i = i + 1
end

if not path then
	die("usage: play [-r rate] FILE")
end

local N = prog.ns() or die("no namespace")

if not sys.usbhost() then
	die("this machine has no usb host controller")
end

-- the port may have nothing on it yet, and enumeration is not instant
local desc

for _ = 1, 30 do
	desc = sys.usbdesc()
	if desc then
		break
	end
	thread.sleep(100)
end

if not desc then
	die("nothing on the usb port")
end

local cfg, why = usb.parse(desc)

if not cfg then
	die(why)
end

local f = N:open(path, "r") or die("cannot open " .. path)
local head = f:read(4096) or die("cannot read " .. path)
local w, err = wav.header(head)

if not w then
	die(path .. ": " .. err)
end

rate = rate or w.rate

local stream, no = uac.playback(cfg, { rate = rate, channels = w.channels,
    width = w.width })

if not stream then
	die(("%s: %d Hz %d ch %d bit: %s"):format(no, rate, w.channels, w.width))
end

local packet = uac.packet(stream, rate)

if not packet then
	die("the device cannot carry that rate")
end

local okp, whyp = sys.usbplay(stream.interface, stream.alt,
    stream.endpoint.address, packet, rate)

if not okp then
	die(whyp)
end

unistd.write(1, ("play: %s, %d Hz %d ch, %.1fs\n"):format(path, rate,
    w.channels, wav.seconds(w)))

-- the samples, from where the header said they start. A short write is
-- the device's pace, so what it would not take is offered again.
f:seek(w.at - 1)

local left = w.bytes
local pending = ""

while left > 0 or #pending > 0 do
	if #pending == 0 then
		local want = left < CHUNK and left or CHUNK

		pending = f:read(want) or ""
		if pending == "" then
			break
		end
		left = left - #pending
	end

	local took = sys.usbwrite(pending)

	if not took then
		die("the device went away")
	end
	pending = pending:sub(took + 1)

	if #pending > 0 then
		thread.sleep(10)
	end
end

-- what is queued is not yet played: the ring holds a fifth of a second
thread.sleep(300)
sys.usbstop()
f:close()

local lost = sys.usbunderruns()

if lost > 0 then
	unistd.write(2, ("play: %d ms of silence for want of audio\n"):format(lost))
end
