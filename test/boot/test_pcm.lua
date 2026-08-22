-- pcm.native: the volume, against a reference written here.
--
-- The C is what the boards run, so what it must agree with is the
-- arithmetic spelled out rather than itself. Clamping is the part
-- worth pinning: a sample scaled past the end of the range wraps to
-- the opposite sign, which is a click and not a loud note.

local tap = require("tap")

tap.plan(8)

local ok, pcm = pcall(require, "pcm.native")

tap.ok(ok and type(pcm) == "table", "pcm.native is ambient")
if not ok then
	tap.done()
	return
end

-- one sample at a time, in lua, so the two can be compared run for run
local function ref(s, q)
	local out = {}

	for i = 1, #s - 1, 2 do
		local lo, hi = s:byte(i, i + 1)
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
		out[#out + 1] = string.pack("<i2", v)
	end
	return table.concat(out) .. (#s % 2 == 1 and s:sub(#s) or "")
end

local loud = string.pack("<i2i2i2", 20000, -20000, 0)

tap.is(pcm.gain(loud, 256), loud, "full gain hands the samples back")
tap.is(pcm.gain(loud, 0), string.pack("<i2i2i2", 0, 0, 0),
    "zero gain is silence")
tap.is(pcm.gain(loud, 128), ref(loud, 128), "half gain matches the reference")

local peak = string.pack("<i2i2", 32000, -32000)
local a, b = string.unpack("<i2i2", pcm.gain(peak, 512))

tap.ok(a == 32767 and b == -32768, "past the range it clamps, not wraps")

-- the whole range, against the reference, at a gain that is not a
-- power of two: rounding is where the two would part company
local every = {}

for v = -32768, 32767, 7 do
	every[#every + 1] = string.pack("<i2", v)
end
every = table.concat(every)

tap.is(pcm.gain(every, 173), ref(every, 173),
    "9363 samples agree with the reference at q=173")

local odd = loud .. "\x7f"

tap.is(#pcm.gain(odd, 128), #odd, "an odd trailing byte is kept")
tap.is(pcm.gain(odd, 128):sub(-1), "\x7f", "and is not scaled")

tap.done()
