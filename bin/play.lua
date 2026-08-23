-- play: a wav file, out of the usb audio device on the port.
--
--	play /sd/music/song.wav
--
-- The device decides what can be played, so a file whose rate it does
-- not list is refused rather than played at the wrong speed.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local audio = require("audio")
local wav = require("wav")
local adpcm = require("adpcm")

-- big enough that the per-read cost is not the pace: a read costs tens
-- of milliseconds whatever its size, and 48kHz stereo is 192KB a second
local CHUNK = 32768

local function die(s)
	io.stderr:write("play: " .. s .. "\n")
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

local f = N:open(path, "r") or die("cannot open " .. path)
local head = f:read(4096) or die("cannot read " .. path)
local w, err = wav.header(head)

if not w then
	die(path .. ": " .. err)
end

rate = rate or w.rate

local dev, why = audio.open(rate, w.channels, w.width)

if not dev then
	die(tostring(why))
end

io.write(("play: %s, %d Hz %d ch, %.1fs, on %s\n"):format(path,
    rate, w.channels, wav.seconds(w), dev.kind))

-- the samples, from where the header said they start. A short write is
-- the device's pace, so what it would not take is offered again.
f:seek("set", w.at - 1)

-- compressed audio is read a whole number of blocks at a time: a block
-- carries the state the next one resumes from, so half of one decodes
-- to nothing.
local step = CHUNK

if w.adpcm then
	step = (CHUNK // w.block) * w.block
	if step < w.block then
		step = w.block
	end
end

local left = w.bytes
local pending = ""
local carry = ""

while left > 0 or #pending > 0 do
	if #pending == 0 then
		local want = left < step and left or step
		local raw = f:read(want) or ""

		if raw == "" then
			break
		end
		left = left - #raw

		if w.adpcm then
			-- a read answers with what it has, not with what
			-- was asked for, so what is left over is the front
			-- of the next block and not something to drop
			raw = carry .. raw

			local out, o = {}, 1

			while o + w.block - 1 <= #raw do
				local d, why = adpcm.block(raw, o,
				    w.channels, w.block)

				if not d then
					die(why)
				end
				out[#out + 1] = d
				o = o + w.block
			end
			carry = raw:sub(o)
			pending = table.concat(out)
		else
			pending = raw
		end
	end

	local took = dev.write(pending)

	if not took then
		die("the device went away")
	end
	pending = pending:sub(took + 1)

	if #pending > 0 then
		thread.sleep(10)
	end
end

-- before the drain: once the file is done the device keeps asking, and
-- what it is answered with is silence by design, not a gap in the audio
local lost = dev.underruns()

-- what is queued is not yet played: the ring holds a fifth of a second
thread.sleep(300)
dev.stop()
f:close()

if lost > 0 then
	io.stderr:write(("play: %d ms of silence for want of audio\n"):format(lost))
end
