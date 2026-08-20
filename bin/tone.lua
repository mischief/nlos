-- tone: write a wav of a sine, so there is something to play.
--
--	tone /sd/a440.wav              440Hz, 3s, 8000Hz stereo
--	tone -r 48000 -f 220 -s 5 x.wav
--
-- A gap in playback is audible as a click, a wrong rate as a wrong note.

local prog = require("prog")
local unistd = require("posix.unistd")

local function die(s)
	unistd.write(2, "tone: " .. s .. "\n")
	os.exit(1)
end

local rate, freq, secs, path = 8000, 440, 3, nil
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-r" or a == "-f" or a == "-s" then
		i = i + 1
		local v = tonumber(arg[i]) or die(a .. " wants a number")

		if a == "-r" then
			rate = math.floor(v)
		elseif a == "-f" then
			freq = v
		else
			secs = v
		end
	else
		path = a
	end
	i = i + 1
end

if not path then
	die("usage: tone [-r rate] [-f hz] [-s seconds] FILE")
end

local N = prog.ns() or die("no namespace")
local frames = math.floor(rate * secs)
local bytes = frames * 4		-- stereo, 16 bit

-- a header with no LIST chunk: the samples start where the fixed part
-- ends, which is what a reader that does not walk chunks assumes.
local hdr = "RIFF" .. string.pack("<I4", 36 + bytes) .. "WAVEfmt " ..
    string.pack("<I4I2I2I4I4I2I2", 16, 1, 2, rate, rate * 4, 4, 16) ..
    "data" .. string.pack("<I4", bytes)

local fd = N:create(path, "w") or N:open(path, "w") or
    die("cannot write " .. path)

fd:write(hdr)

-- a block at a time: a whole file of samples is megabytes, and this
-- machine would rather write than hold them.
local BLOCK = 1024
local step = 2 * math.pi * freq / rate
local out = {}

for n = 0, frames - 1 do
	local v = math.floor(math.sin(n * step) * 12000)

	out[#out + 1] = string.pack("<i2i2", v, v)
	if #out == BLOCK then
		fd:write(table.concat(out))
		out = {}
	end
end
if #out > 0 then
	fd:write(table.concat(out))
end
fd:close()

io.write(("tone: %s, %dHz at %d, %.1fs, %d bytes\n"):format(path, freq,
    rate, secs, bytes))
