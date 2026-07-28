-- json: minimal pure-lua JSON encode/decode. no C library (no
-- cjson) -- consistent with every other protocol in this repo being
-- hand-rolled (dns, 9p, http itself all speak their wire format
-- directly in lua, no third-party deps).
--
-- lua tables don't distinguish empty-array from empty-object, and a
-- table with a nil "hole" isn't reliably countable via # -- two real
-- ambiguities this resolves with sentinels rather than guessing:
--   json.null       -- explicit JSON null (Lua nil can't live in a
--                      table as a value at all, so decode uses this
--                      instead of nil, and encode treats it as null)
--   json.EMPTY_ARRAY -- pass this instead of {} when you specifically
--                      mean [] (an empty {} always encodes as {})

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })
M.EMPTY_ARRAY = setmetatable({}, { __tostring = function() return "[]" end })

-- ---- decode ----

local function skip_ws(s, i)
	while i <= #s and s:sub(i, i):match("%s") do
		i = i + 1
	end
	return i
end

local decode_value	-- forward decl, mutually recursive with object/array

local function decode_string(s, i)
	i = i + 1	-- past opening quote
	local out = {}

	while true do
		local c = s:sub(i, i)
		if c == "" then
			error("unterminated string")
		elseif c == '"' then
			return table.concat(out), i + 1
		elseif c == "\\" then
			local e = s:sub(i + 1, i + 1)
			if e == "n" then
				out[#out + 1] = "\n"
			elseif e == "t" then
				out[#out + 1] = "\t"
			elseif e == "r" then
				out[#out + 1] = "\r"
			elseif e == "b" then
				out[#out + 1] = "\b"
			elseif e == "f" then
				out[#out + 1] = "\f"
			elseif e == '"' or e == "\\" or e == "/" then
				out[#out + 1] = e
			elseif e == "u" then
				local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0

				-- basic BMP-only utf8 encode (no surrogate
				-- pair handling -- fine for the ascii-heavy
				-- protocol traffic this is actually for)
				if cp < 0x80 then
					out[#out + 1] = string.char(cp)
				elseif cp < 0x800 then
					out[#out + 1] = string.char(
					    0xC0 | (cp >> 6),
					    0x80 | (cp & 0x3F))
				else
					out[#out + 1] = string.char(
					    0xE0 | (cp >> 12),
					    0x80 | ((cp >> 6) & 0x3F),
					    0x80 | (cp & 0x3F))
				end
				i = i + 4
			else
				error("bad escape: \\" .. e)
			end
			i = i + 2
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
end

local function decode_number(s, i)
	local j = i

	if s:sub(j, j) == "-" then
		j = j + 1
	end
	while s:sub(j, j):match("%d") do
		j = j + 1
	end
	if s:sub(j, j) == "." then
		j = j + 1
		while s:sub(j, j):match("%d") do
			j = j + 1
		end
	end
	if s:sub(j, j) == "e" or s:sub(j, j) == "E" then
		j = j + 1
		if s:sub(j, j) == "+" or s:sub(j, j) == "-" then
			j = j + 1
		end
		while s:sub(j, j):match("%d") do
			j = j + 1
		end
	end
	if j == i then
		error("bad number at " .. i)
	end
	return tonumber(s:sub(i, j - 1)), j
end

decode_value = function(s, i)
	i = skip_ws(s, i)

	local c = s:sub(i, i)

	if c == '"' then
		return decode_string(s, i)
	elseif c == "{" then
		local obj = {}

		i = skip_ws(s, i + 1)
		if s:sub(i, i) == "}" then
			return obj, i + 1
		end
		while true do
			i = skip_ws(s, i)
			if s:sub(i, i) ~= '"' then
				error("expected string key at " .. i)
			end
			local key

			key, i = decode_string(s, i)
			i = skip_ws(s, i)
			if s:sub(i, i) ~= ":" then
				error("expected ':' at " .. i)
			end
			i = skip_ws(s, i + 1)

			local val

			val, i = decode_value(s, i)
			obj[key] = val
			i = skip_ws(s, i)

			local d = s:sub(i, i)

			if d == "," then
				i = i + 1
			elseif d == "}" then
				return obj, i + 1
			else
				error("expected ',' or '}' at " .. i)
			end
		end
	elseif c == "[" then
		local arr = {}

		i = skip_ws(s, i + 1)
		if s:sub(i, i) == "]" then
			return arr, i + 1
		end
		while true do
			local val

			val, i = decode_value(s, i)
			arr[#arr + 1] = val
			i = skip_ws(s, i)

			local d = s:sub(i, i)

			if d == "," then
				i = i + 1
			elseif d == "]" then
				return arr, i + 1
			else
				error("expected ',' or ']' at " .. i)
			end
		end
	elseif s:sub(i, i + 3) == "true" then
		return true, i + 4
	elseif s:sub(i, i + 4) == "false" then
		return false, i + 5
	elseif s:sub(i, i + 3) == "null" then
		return M.null, i + 4
	elseif c:match("[%d%-]") then
		return decode_number(s, i)
	else
		error("unexpected character '" .. c .. "' at " .. i)
	end
end

-- returns the decoded value, or nil + "reason" on malformed input.
-- trailing content after the top-level value is an error, not
-- something to ignore: this parses whole network requests, where
-- "{...} <anything>" means the sender and this parser disagree about
-- the message, and guessing which half is right is how smuggling
-- bugs start.
function M.decode(s)
	local ok, v, pos = pcall(decode_value, s, 1)
	if not ok then
		return nil, v
	end
	pos = skip_ws(s, pos)
	if pos <= #s then
		return nil, "trailing garbage at " .. pos
	end
	return v
end

-- ---- encode ----

local encode_value	-- forward decl

local function is_array(t)
	if t == M.EMPTY_ARRAY then
		return true
	end
	local n = 0

	for _ in pairs(t) do
		n = n + 1
	end
	return n > 0 and n == #t
end

local ESCAPES = {
	["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
	["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local function encode_string(s)
	return '"' .. s:gsub('[\\"\n\r\t\b\f]', ESCAPES) .. '"'
end

local function encode_array(t)
	local parts = {}

	for i = 1, #t do
		parts[i] = encode_value(t[i])
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

local function encode_object(t)
	local parts = {}

	for k, v in pairs(t) do
		parts[#parts + 1] = encode_string(tostring(k)) .. ":" ..
		    encode_value(v)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v)
	if v == nil or v == M.null then
		return "null"
	elseif v == M.EMPTY_ARRAY then
		return "[]"
	end

	local t = type(v)

	if t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		return tostring(v)
	elseif t == "string" then
		return encode_string(v)
	elseif t == "table" then
		if next(v) == nil then
			return "{}"
		end
		if is_array(v) then
			return encode_array(v)
		end
		return encode_object(v)
	else
		error("cannot encode a " .. t)
	end
end

function M.encode(v)
	return encode_value(v)
end

return M
