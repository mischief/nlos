-- Bech32 and Bech32m, BIP 173 and BIP 350.
--
-- A human-readable prefix, a separator, data in base 32 and a six
-- character BCH checksum. What wants it here is nostr: npub, nsec and
-- note are bech32 over 32 bytes, and NIP-19 lifts the 90 character limit
-- that BIP 173 states, so `limit` is a caller's argument.

local M = {}

local byte, char, sub, lower = string.byte, string.char, string.sub, string.lower
local concat = table.concat

local ALPHA = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
local BECH32, BECH32M = 1, 0x2bc830a3

local rev = {}
for i = 1, #ALPHA do rev[sub(ALPHA, i, i)] = i - 1 end

M.LIMIT = 90

-- The BCH code of BIP 173, over GF(32).
local GEN = { 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 }

local function polymod(values, n)
  local chk = 1
  for i = 1, n do
    local top = chk >> 25
    chk = ((chk & 0x1ffffff) << 5) ~ values[i]
    for j = 0, 4 do
      if (top >> j) & 1 == 1 then chk = chk ~ GEN[j + 1] end
    end
  end
  return chk
end

-- The prefix goes into the checksum twice: the high bits of every
-- character, a zero, then the low bits.
local function expand(hrp, out)
  local n = #hrp
  for i = 1, n do out[i] = byte(hrp, i) >> 5 end
  out[n + 1] = 0
  for i = 1, n do out[n + 1 + i] = byte(hrp, i) & 31 end
  return 2 * n + 1
end

-- encode(hrp, data, opts) -> string, or nil plus a reason.
--
--   data     a list of 5-bit values, 0 .. 31
--   opts.m   Bech32m rather than Bech32
--   opts.limit  longest result to produce, false for no limit
function M.encode(hrp, data, opts)
  opts = opts or {}
  local limit = opts.limit
  if limit == nil then limit = M.LIMIT end
  if hrp == "" then return nil, "empty prefix" end

  -- The checksum is over the lowercase form, so that is what goes out.
  hrp = lower(hrp)
  for i = 1, #hrp do
    local c = byte(hrp, i)
    if c < 33 or c > 126 then return nil, "prefix character out of range" end
  end

  local values = {}
  local n = expand(hrp, values)
  for i = 1, #data do
    local v = data[i]
    if type(v) ~= "number" or v < 0 or v > 31 or v % 1 ~= 0 then
      return nil, "data is not 5-bit values"
    end
    values[n + i] = v
  end
  n = n + #data
  for i = 1, 6 do values[n + i] = 0 end

  local mod = polymod(values, n + 6) ~ (opts.m and BECH32M or BECH32)
  local out = { hrp, "1" }
  for i = 1, #data do out[i + 2] = sub(ALPHA, data[i] + 1, data[i] + 1) end
  for i = 0, 5 do
    local v = (mod >> (5 * (5 - i))) & 31
    out[#data + 3 + i] = sub(ALPHA, v + 1, v + 1)
  end

  local s = concat(out)
  if limit and #s > limit then return nil, "too long" end
  return s
end

-- decode(s, opts) -> hrp, data, spec, where spec is "bech32" or
-- "bech32m". A string that is neither is an error, not a third answer:
-- the two checksums exist to tell the two apart.
function M.decode(s, opts)
  opts = opts or {}
  local limit = opts.limit
  if limit == nil then limit = M.LIMIT end
  if limit and #s > limit then return nil, "too long" end

  local hasupper, haslower = false, false
  for i = 1, #s do
    local c = byte(s, i)
    if c < 33 or c > 126 then return nil, "character out of range" end
    if c >= 65 and c <= 90 then hasupper = true end
    if c >= 97 and c <= 122 then haslower = true end
  end
  if hasupper and haslower then return nil, "mixed case" end
  s = lower(s)

  local pos = s:find("1[^1]*$")
  if not pos then return nil, "no separator" end
  if pos == 1 then return nil, "empty prefix" end
  if #s - pos < 6 then return nil, "checksum is too short" end

  local hrp = sub(s, 1, pos - 1)
  local values = {}
  local n = expand(hrp, values)
  local data = {}
  for i = pos + 1, #s do
    local v = rev[sub(s, i, i)]
    if not v then return nil, "invalid data character" end
    n = n + 1
    values[n] = v
    data[#data + 1] = v
  end

  local mod = polymod(values, n)
  local spec
  if mod == BECH32 then spec = "bech32"
  elseif mod == BECH32M then spec = "bech32m"
  else return nil, "bad checksum" end
  if opts.m ~= nil and opts.m ~= (spec == "bech32m") then
    return nil, "wrong checksum for this variant"
  end

  for _ = 1, 6 do data[#data] = nil end
  return hrp, data, spec
end

-- Regroup bits, 8 to 5 to encode and 5 to 8 to decode. Padding is added
-- going up and refused going down: a decoder that accepts leftover bits
-- accepts two encodings of the same bytes.
function M.convertbits(data, from, to, pad)
  local acc, bits, out = 0, 0, {}
  local maxv = (1 << to) - 1
  for i = 1, #data do
    local v = data[i]
    if v < 0 or (v >> from) ~= 0 then return nil, "value out of range" end
    acc = ((acc << from) | v) & 0xffffffff
    bits = bits + from
    while bits >= to do
      bits = bits - to
      out[#out + 1] = (acc >> bits) & maxv
    end
  end
  if pad then
    if bits > 0 then out[#out + 1] = (acc << (to - bits)) & maxv end
  elseif bits >= from or ((acc << (to - bits)) & maxv) ~= 0 then
    return nil, "padding is not zero"
  end
  return out
end

-- The pair a caller normally wants: bytes in, string out, and back.
function M.encode_bytes(hrp, s, opts)
  local data = {}
  for i = 1, #s do data[i] = byte(s, i) end
  data = M.convertbits(data, 8, 5, true)
  return M.encode(hrp, data, opts)
end

function M.decode_bytes(s, opts)
  local hrp, data, spec = M.decode(s, opts)
  if not hrp then return nil, data end
  local bytes, err = M.convertbits(data, 5, 8, false)
  if not bytes then return nil, err end
  local out = {}
  for i = 1, #bytes do out[i] = char(bytes[i]) end
  return hrp, concat(out), spec
end

return M
