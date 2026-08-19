#!/usr/bin/env lua5.4
-- lib/usb and lib/uac, against a real device's descriptors.
--
-- The bytes below are what a USB-C headphone adapter answered on an
-- ESP32-S3, copied out of the kernel log. A parser tested against
-- descriptors somebody wrote by hand is tested against their reading of
-- the spec; this one is tested against a device.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local usb = require("usb")
local uac = require("uac")
local wav = require("wav")

local n, fails = 0, 0

local function ok(cond, name)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, name))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, name))
	end
end

local function bytes(hex)
	return (hex:gsub("%s+", ""):gsub("%x%x", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- vid 001f pid 0b26: a UAC1 headset, 4 interfaces, 235 bytes
local DESC = bytes([[
09 02 eb 00 04 01 00 80 32 09 04 00 00 00 01 01
00 00 0a 24 01 00 01 55 00 02 01 02 0c 24 02 01
01 01 00 02 03 00 00 00 0d 24 04 05 02 05 05 02
03 00 00 00 00 0a 24 06 02 01 01 01 02 02 00 09
24 03 03 01 03 00 02 00 0c 24 02 04 01 02 00 02
03 00 00 00 0a 24 06 05 04 01 03 00 00 00 09 24
03 06 01 01 00 05 00 09 04 01 00 00 01 02 00 00
09 04 01 01 01 01 02 00 00 07 24 01 01 01 01 00
0e 24 02 01 02 02 10 02 40 1f 00 80 bb 00 09 05
03 0d 80 01 01 00 00 07 25 01 01 01 01 00 09 04
02 00 00 01 02 00 00 09 04 02 01 01 01 02 00 00
07 24 01 06 01 01 00 0b 24 02 01 02 02 10 01 80
bb 00 09 05 83 0d d0 00 01 00 00 07 25 01 01 00
00 00 09 04 03 00 01 03 00 00 00 09 21 01 02 00
01 22 36 00 07 05 82 03 10 00 01
]])

ok(#DESC == 235, "the fixture is the whole descriptor set")

local cfg, why = usb.parse(DESC)

ok(cfg ~= nil, "it parses: " .. tostring(why))
ok(cfg.total == 235 and cfg.ninterfaces == 4,
    "the header agrees with what followed it")
ok(not cfg.selfpowered and cfg.maxpower == 100,
    "bus powered, and it asks for 100mA")

-- 4 interfaces, but 6 alternate settings: streaming interfaces carry a
-- silent alt 0 apiece.
ok(#cfg.interfaces == 6, "every alternate setting is its own entry")

local ac = cfg.interfaces[1]

ok(ac.class == usb.AUDIO and ac.subclass == usb.AUDIOCONTROL,
    "the first interface is the control one")
-- header, then two chains of terminal, unit, terminal: one out to the
-- speaker and one back from the microphone.
ok(#ac.cs == 8, "and it carries the unit and terminal records")

local streams = uac.streams(cfg)

ok(#streams == 2, "two streams: one out, one in")

local play, err = uac.playback(cfg)

ok(play ~= nil, "there is a playback stream: " .. tostring(err))
ok(play.interface == 1 and play.alt == 1,
    "on interface 1, alternate setting 1")
ok(play.endpoint.address == 0x03 and not play.endpoint.input,
    "through the OUT endpoint")
ok(play.endpoint.transfer == usb.ISOCHRONOUS,
    "which is isochronous, as audio has to be")
ok(usb.syncof(play.endpoint) == usb.SYNC_SYNC,
    "and synchronous, so the frame clock sets the pace")
ok(play.format.channels == 2 and play.format.width == 16,
    "stereo, 16 bits a sample")
ok(#play.format.rates == 2 and play.format.rates[1] == 8000 and
    play.format.rates[2] == 48000, "at 8000 or 48000 Hz")

-- the rate is the highest on offer unless somebody asks for another
ok(uac.rateof(play) == 48000, "left open, it runs at the fastest rate")
ok(uac.rateof(play, 8000) == 8000, "and asks for the one named")

ok(uac.packet(play) == 192, "one millisecond is 192 bytes at 48k stereo")
ok(play.endpoint.maxpacket == 384,
    "which the endpoint's 384 has room for")

-- a rate the device did not list is not one to ask for. Sending 44100
-- to a device that named 8000 and 48000 plays at the wrong speed rather
-- than failing, so the check belongs here.
local none, no = uac.playback(cfg, { rate = 44100 })

ok(none == nil and no == "not that rate",
    "an unlisted rate is refused rather than played wrong")

local sixteen = uac.playback(cfg, { rate = 8000 })

ok(sixteen ~= nil and uac.packet(sixteen, 8000) == 32,
    "and a listed one narrows the packet to match")

-- the capture stream is found, and is not offered as playback
local mic

for _, s in ipairs(streams) do
	if not s.output then
		mic = s
	end
end

ok(mic ~= nil and mic.endpoint.address == 0x83,
    "the microphone is on the IN endpoint")

-- a device with nothing to play says so rather than answering nil twice
local onlymic = usb.parse(bytes([[
09 02 20 00 01 01 00 80 32
09 04 02 01 01 01 02 00 00
0b 24 02 01 02 02 10 01 80 bb 00
09 05 83 0d d0 00 01 00 00
]]))

local nostream, saidwhy = uac.playback(onlymic)

ok(nostream == nil and saidwhy == "this device only records",
    "a microphone is not a fault, and says which it is")

-- a truncated set stops at the last whole record rather than reading
-- past it: descriptors arrive over the wire and a short read happens.
local short = usb.parse(DESC:sub(1, 40))

ok(short ~= nil and #short.interfaces >= 1,
    "a short descriptor gives up what it holds")

-- ---- lib/wav ----
--
-- A header written the simple way, and one with a LIST chunk in front
-- of the samples. The second is what a real encoder writes.
local function riff(extra)
	local fmt = "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 2, 48000,
	    48000 * 4, 4, 16)
	local body = "WAVE" .. fmt .. (extra or "") .. "data" ..
	    string.pack("<I4", 8) .. ("\0"):rep(8)

	return "RIFF" .. string.pack("<I4", #body) .. body
end

local w, wwhy = wav.header(riff())

ok(w ~= nil, "a wav header parses: " .. tostring(wwhy))
ok(w.channels == 2 and w.rate == 48000 and w.width == 16,
    "stereo 48k 16-bit, as the format chunk says")
ok(w.frame == 4, "which is four bytes a frame")
ok(riff():sub(w.at, w.at + 1) == "\0\0", "and at points at the samples")
ok(w.bytes == 8, "with the length the data chunk gave")

-- a LIST chunk before the data moves the samples. A reader that assumed
-- offset 45 would play the chunk's text.
local tagged = riff("LIST" .. string.pack("<I4", 10) .. "INFOhello\0")
local t = wav.header(tagged)

ok(t ~= nil and t.at ~= w.at, "a chunk before the samples moves them")
ok(tagged:sub(t.at, t.at + 1) == "\0\0", "and they are still found")

ok(select(2, wav.header("not a wav at all")) == "not a wav",
    "something else is refused")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
