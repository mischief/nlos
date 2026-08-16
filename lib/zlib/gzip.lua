-- The gzip container, RFC 1952: a header, a raw deflate stream, and a
-- CRC-32 with the uncompressed length. What `gzip` and `zcat` read.
--
-- Members concatenate, and a decoder must accept that, so `decompress`
-- keeps going until the input runs out.

local deflate = require "zlib.deflate"
local inflate = require "zlib.inflate"

local M = {}

local byte, sub, spack, sunpack = string.byte, string.sub, string.pack, string.unpack
local concat = table.concat

local FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT = 1, 2, 4, 8, 16

local crctab = {}
do
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      c = (c & 1) ~= 0 and (0xedb88320 ~ (c >> 1)) or (c >> 1)
    end
    crctab[i] = c
  end
end

function M.crc32(s, crc)
  local c = (crc or 0) ~ 0xffffffff
  for i = 1, #s do
    c = crctab[(c ~ byte(s, i)) & 0xff] ~ (c >> 8)
  end
  return c ~ 0xffffffff
end

-- lua-os has this in C for zmodem, over the same polynomial. It is an
-- update primitive: the register in and out, with neither complement, so
-- both belong here.
local ok, crc = pcall(require, "los.crc")
if ok and type(crc) == "table" and crc.crc32 then
  M.pure = M.crc32
  M.native = function(s, seed)
    return ~crc.crc32(s, (seed or 0) ~ 0xffffffff) & 0xffffffff
  end
  M.crc32 = M.native
end

-- `opts.name` and `opts.mtime` go in the header; both are optional, and
-- an absent mtime is written as zero, which RFC 1952 defines as "none".
function M.compress(s, opts)
  opts = opts or {}
  local flg = opts.name and FNAME or 0
  local hdr = spack("<BBBBI4BB", 0x1f, 0x8b, 8, flg, opts.mtime or 0, 0, 255)
  if opts.name then hdr = hdr .. opts.name .. "\0" end
  return hdr .. deflate.compress(s, opts)
      .. spack("<I4I4", M.crc32(s), #s % 0x100000000)
end

-- Header of one member: the byte where its deflate stream starts, or nil
-- plus a reason.
local function header(s, p)
  if #s - p + 1 < 10 then return nil, "short gzip header" end
  local id1, id2, cm, flg = byte(s, p, p + 3)
  if id1 ~= 0x1f or id2 ~= 0x8b then return nil, "not gzip" end
  if cm ~= 8 then return nil, "not deflate" end
  if flg & 0xe0 ~= 0 then return nil, "reserved flag set" end
  p = p + 10

  if flg & FEXTRA ~= 0 then
    if #s - p + 1 < 2 then return nil, "truncated extra field" end
    p = p + 2 + sunpack("<I2", s, p)
  end
  for _, f in ipairs { FNAME, FCOMMENT } do
    if flg & f ~= 0 then
      local z = s:find("\0", p, true)
      if not z then return nil, "unterminated header string" end
      p = z + 1
    end
  end
  if flg & FHCRC ~= 0 then p = p + 2 end
  if p > #s then return nil, "truncated gzip header" end
  return p
end

function M.decompress(s)
  local out, n, p = {}, 0, 1
  while p <= #s do
    local start, err = header(s, p)
    if not start then return nil, err end

    local z = inflate.new()
    local data
    data, err = z:update(sub(s, start))
    if not data then return nil, err end
    if not z:finished() then return nil, "truncated deflate stream" end

    local tail = z:unused()
    if #tail < 8 then return nil, "truncated gzip trailer" end
    local crc, isize = sunpack("<I4I4", tail)
    if crc ~= M.crc32(data) then return nil, "crc32 mismatch" end
    if isize ~= #data % 0x100000000 then return nil, "length mismatch" end

    n = n + 1
    out[n] = data
    p = #s - #tail + 9
  end
  if n == 0 then return nil, "empty input" end
  return concat(out, "", 1, n)
end

return M
