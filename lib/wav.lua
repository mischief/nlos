-- wav: the header of a RIFF file, and where its samples begin.
--
-- Chunks are walked rather than assumed: a file written by anything
-- other than the simplest encoder carries LIST or fact chunks before
-- the data, and a reader that seeks to a fixed offset plays those as
-- audio.

local M = {}

local function u16(s, i)
	return s:byte(i) | (s:byte(i + 1) << 8)
end

local function u32(s, i)
	return s:byte(i) | (s:byte(i + 1) << 8) | (s:byte(i + 2) << 16) |
	    (s:byte(i + 3) << 24)
end

-- header(bytes) -> info, or nil and why
--
-- Wants enough of the front of the file to hold the chunks before the
-- samples. info.at is where those samples start, one-based.
function M.header(s)
	if #s < 12 or s:sub(1, 4) ~= "RIFF" or s:sub(9, 12) ~= "WAVE" then
		return nil, "not a wav"
	end

	local w = {}
	local i = 13

	while i + 7 <= #s do
		local id = s:sub(i, i + 3)
		local len = u32(s, i + 4)
		local body = i + 8

		if id == "fmt " then
			if body + 15 > #s then
				return nil, "truncated format chunk"
			end
			w.format = u16(s, body)
			w.channels = u16(s, body + 2)
			w.rate = u32(s, body + 4)
			w.width = u16(s, body + 14)
		elseif id == "data" then
			w.at = body
			w.bytes = len
			break
		end

		-- chunks are padded to an even length, and the pad is not
		-- counted in the one they report
		i = body + len + (len % 2)
	end

	if not w.format then
		return nil, "no format chunk"
	end
	if not w.at then
		return nil, "no data chunk"
	end
	if w.format ~= 1 then
		return nil, "not pcm"
	end
	w.frame = w.channels * (w.width // 8)
	return w
end

-- seconds(info) -> how long it plays
function M.seconds(w)
	return w.bytes / (w.rate * w.frame)
end

return M
