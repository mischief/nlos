-- adpcm: IMA ADPCM, as a WAV file carries it.
--
-- Four bits a sample against sixteen: each nibble says how far to step
-- from the last sample, and a table says how big the steps get.
-- Blocks are independent -- each carries the predictor and index it
-- resumes from -- so decoding may start at any block boundary.

local M = {}

local sbyte, schar, srep = string.byte, string.char, string.rep

-- how the step index moves for each nibble: quiet ones shrink it,
-- loud ones grow it, so the step follows the signal.
local INDEX = { [0] = -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8 }

-- the 89 step sizes, each about 1.1 times the last. From the IMA
-- specification; a decoder that rounds them differently drifts.
local STEP = { [0] =
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
	19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
	130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
	5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767 }

-- one channel's nibble. Kept as a local rather than a method: this is
-- the whole cost of decoding, run twice per frame.
local function step(pred, idx, nib)
	local s = STEP[idx]
	local d = s >> 3

	if nib & 4 ~= 0 then
		d = d + s
	end
	if nib & 2 ~= 0 then
		d = d + (s >> 1)
	end
	if nib & 1 ~= 0 then
		d = d + (s >> 2)
	end
	if nib & 8 ~= 0 then
		pred = pred - d
	else
		pred = pred + d
	end

	if pred > 32767 then
		pred = 32767
	elseif pred < -32768 then
		pred = -32768
	end

	idx = idx + INDEX[nib]
	if idx < 0 then
		idx = 0
	elseif idx > 88 then
		idx = 88
	end
	return pred, idx
end

-- a signed 16-bit sample as the two bytes a wav wants
local function le16(v)
	if v < 0 then
		v = v + 65536
	end
	return schar(v & 0xff, v >> 8)
end

-- block(s, at, channels, len) -> pcm, or nil and why
--
-- `at` is one-based and `len` is the block's own length: a block ends
-- where the format says, not where the string does, and a decoder that
-- reads past it takes the next block's predictor for audio.
--
-- Each channel opens with its predictor and index, and the nibbles
-- then arrive four bytes of one channel at a time, so a stereo block
-- reads as alternating runs of eight samples rather than as pairs.
function M.block(s, at, channels, len)
	local pred, idx = {}, {}
	local n = len or (#s - at + 1)

	if n < channels * 4 or at + n - 1 > #s then
		return nil, "short block"
	end

	for c = 1, channels do
		local o = at + (c - 1) * 4
		local p = sbyte(s, o) | (sbyte(s, o + 1) << 8)

		if p >= 32768 then
			p = p - 65536
		end
		pred[c] = p
		idx[c] = sbyte(s, o + 2)
		if idx[c] > 88 then
			return nil, "bad step index"
		end
	end

	-- the predictor is the first sample, not a value before it
	local out = { }

	for c = 1, channels do
		out[c] = le16(pred[c])
	end

	local o = at + channels * 4
	local last = at + n - 1
	local run = {}

	while o + channels * 4 - 1 <= last do
		-- eight samples of each channel, in channel order
		for c = 1, channels do
			local p, i = pred[c], idx[c]
			local t = run[c] or {}

			for k = 0, 3 do
				local b = sbyte(s, o + k)

				p, i = step(p, i, b & 0x0f)
				t[k * 2 + 1] = le16(p)
				p, i = step(p, i, b >> 4)
				t[k * 2 + 2] = le16(p)
			end
			pred[c], idx[c] = p, i
			run[c] = t
			o = o + 4
		end

		-- interleave the two runs of eight
		for k = 1, 8 do
			for c = 1, channels do
				out[#out + 1] = run[c][k]
			end
		end
	end
	return table.concat(out)
end

-- samples(blockalign, channels) -> frames one block holds
function M.samples(blockalign, channels)
	return 1 + ((blockalign - channels * 4) * 2) // channels
end

-- silence(frames, channels) -> what to play where a block was lost
function M.silence(frames, channels)
	return srep("\0", frames * channels * 2)
end

-- The C one when it is there, which on every real machine it is. The
-- Lua above stays as `pure`: the host test runs both over the same
-- blocks, so a difference between them is caught rather than shipped.
M.pure = M.block

local ok, native = pcall(require, "adpcm.native")

if ok and native and native.block then
	M.block = native.block
	M.native = true
end

return M
