-- uac: the audio class, over a parsed configuration.
--
-- A UAC device describes what it can play as a set of alternate
-- settings on a streaming interface. Choosing one is the whole job:
-- rate, width, channels and the endpoint follow from it, and a rate the
-- device does not list is not a rate it can be asked for.

local usb = require("usb")

local M = {}

-- audio streaming descriptor subtypes
local AS_GENERAL = 0x01
local FORMAT_TYPE = 0x02

-- the terminal an output stream ends at, which is what tells playback
-- from capture without guessing from the endpoint direction alone.
M.SPEAKER = 0x0301
M.HEADPHONES = 0x0302

-- format(rec) -> { channels, width, rates }
--
-- Type I PCM only. bSamFreqType 0 means the device names a continuous
-- range by its two bounds rather than a list.
local function format(b)
	local f = {
		channels = usb.u8(b, 5),
		width = usb.u8(b, 7),		-- bits, not bytes
		frame = usb.u8(b, 6),		-- bytes a sample a channel
		rates = {},
	}
	local kind = usb.u8(b, 8)

	if kind == 0 then
		f.low, f.high = usb.u24(b, 9), usb.u24(b, 12)
	else
		for i = 1, kind do
			f.rates[i] = usb.u24(b, 9 + (i - 1) * 3)
		end
	end
	return f
end

-- streams(cfg) -> every playable alternate setting
--
-- Alt 0 of a streaming interface carries no endpoint: it is the setting
-- that asks for no bandwidth, and selecting it is how a stream stops.
-- It is not a stream, so it is not listed.
function M.streams(cfg)
	local out = {}

	for _, itf in ipairs(cfg.interfaces) do
		if itf.class == usb.AUDIO and
		    itf.subclass == usb.AUDIOSTREAMING and
		    #itf.endpoints > 0 then
			local s = {
				interface = itf.number,
				alt = itf.alt,
				endpoint = itf.endpoints[1],
			}

			for _, cs in ipairs(itf.cs) do
				if cs.type == usb.CS_INTERFACE then
					if cs.subtype == AS_GENERAL then
						s.terminal = usb.u8(cs.bytes, 4)
					elseif cs.subtype == FORMAT_TYPE then
						s.format = format(cs.bytes)
					end
				end
			end

			if s.format then
				s.output = not s.endpoint.input
				out[#out + 1] = s
			end
		end
	end
	return out
end

local function supports(s, rate)
	if not rate then
		return true
	end
	if s.format.low then
		return rate >= s.format.low and rate <= s.format.high
	end
	for _, r in ipairs(s.format.rates) do
		if r == rate then
			return true
		end
	end
	return false
end

-- playback(cfg, want) -> stream, or nil and why
--
-- want.rate, want.channels and want.width narrow the choice; anything
-- left open takes the best on offer, which is the highest rate at the
-- widest sample. A device with no output stream is not a fault worth a
-- traceback: a microphone is a legitimate thing to plug in.
function M.playback(cfg, want)
	want = want or {}

	local best, why

	for _, s in ipairs(M.streams(cfg)) do
		if not s.output then
			why = why or "this device only records"
		elseif want.channels and s.format.channels ~= want.channels then
			why = why or "not that many channels"
		elseif want.width and s.format.width ~= want.width then
			why = why or "not that sample width"
		elseif not supports(s, want.rate) then
			why = why or "not that rate"
		elseif s.endpoint.transfer ~= usb.ISOCHRONOUS then
			why = why or "the audio endpoint is not isochronous"
		else
			local a = best and M.rateof(best, want.rate) or -1

			if M.rateof(s, want.rate) > a then
				best = s
			end
		end
	end

	if not best then
		return nil, why or "no audio stream here"
	end
	return best
end

-- rateof(stream, want) -> the rate this stream would run at
function M.rateof(s, want)
	if want then
		return want
	end
	if s.format.low then
		return s.format.high
	end

	local hi = 0

	for _, r in ipairs(s.format.rates) do
		hi = r > hi and r or hi
	end
	return hi
end

-- bytes a second, which is what a buffer has to keep up with
function M.rateofbytes(s, rate)
	return M.rateof(s, rate) * s.format.channels * s.format.frame
end

-- what one 1ms packet holds at this rate. The endpoint has to be able
-- to carry it, and a device that cannot is one we would overrun.
function M.packet(s, rate)
	local n = M.rateofbytes(s, rate) // 1000

	if n > s.endpoint.maxpacket then
		return nil, "packets larger than the endpoint takes"
	end
	return n
end

return M
