-- DEFLATE and the two containers built on it.
--
-- Here: the zlib container of RFC 1950, two header bytes and an Adler-32
-- around a raw deflate stream. `zlib.gzip` is the other one, `zlib.deflate`
-- and `zlib.inflate` are the codec itself, raw and streaming.

local deflate = require "zlib.deflate"
local inflate = require "zlib.inflate"
local gzip = require "zlib.gzip"

local M = { deflate = deflate, inflate = inflate, gzip = gzip }

local byte, sub, spack, sunpack = string.byte, string.sub, string.pack, string.unpack

-- The largest run that cannot overflow the sums, RFC 1950 9.
local NMAX = 5552

function M.adler32(s, adler)
  local a = (adler or 1) & 0xffff
  local b = ((adler or 1) >> 16) & 0xffff
  for i = 1, #s, NMAX do
    local j = i + NMAX - 1
    if j > #s then j = #s end
    for k = i, j do
      a = a + byte(s, k)
      b = b + a
    end
    a, b = a % 65521, b % 65521
  end
  return (b << 16) | a
end

-- CMF/FLG: deflate, a 32 KiB window, no preset dictionary, and the check
-- bits that make the pair a multiple of 31.
local function head(level)
  local cmf, flg = 0x78, (level or 6) >= 9 and 0xc0 or 0x80
  flg = flg | (31 - (cmf * 256 + flg) % 31)
  return spack(">BB", cmf, flg)
end

function M.compress(s, opts)
  return head(opts and opts.level)
      .. deflate.compress(s, opts)
      .. spack(">I4", M.adler32(s))
end

function M.decompress(s)
  if #s < 6 then return nil, "short zlib stream" end
  local cmf, flg = byte(s, 1, 2)
  if cmf & 0x0f ~= 8 then return nil, "not deflate" end
  if cmf >> 4 > 7 then return nil, "window too large" end
  if (cmf * 256 + flg) % 31 ~= 0 then return nil, "bad zlib header" end
  if flg & 0x20 ~= 0 then return nil, "preset dictionary" end

  local out, err = inflate.decompress(sub(s, 3, #s - 4))
  if not out then return nil, err end
  if sunpack(">I4", s, #s - 3) ~= M.adler32(out) then
    return nil, "adler32 mismatch"
  end
  return out
end

return M
