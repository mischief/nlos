-- metrohash64_1, seeded with 0x6765, which is what gefs checksums blocks
-- with. Ported from J. Andrew Rogers' reference implementation via
-- 9front's hash.c.
--
-- This is not a cryptographic hash and is not asked to be: it catches a
-- torn or misdirected write, and every block pointer carries the hash of
-- what it points at, so corruption is found on the way in rather than
-- discovered later as nonsense.
--
-- Lua 5.4 integers are exactly the 64-bit wrapping arithmetic this wants,
-- and >> is a logical shift, so the C translates directly.
--
-- If gefs.native is present its C implementation is used instead. The
-- Lua one stays reachable as M.pure, which is what runs where no C is
-- available and what the spec suite checks the C against, making the two
-- a differential test of each other. This is the one hot loop in the
-- tree: every block read verifies a hash over the whole block and every
-- block written computes one.
--
-- Two things about the reads. They are little-endian, matching an
-- unaligned load on amd64; a volume written on a big-endian machine
-- would checksum differently, and gefs has the same property. And the
-- tails below 8 bytes are unreachable for every use gefs makes of this
-- -- blocks are 16KiB, log bodies are a multiple of 8, and the
-- superblock prefix is 104+16n bytes -- so the one place where the
-- reference implementation's 64-bit promotion could be read two ways
-- never runs.

local M = {}

local sunpack = string.unpack

local K0 = 0xC83A91E1
local K1 = 0x8648DBDB
local K2 = 0x7BDEC03B
local K3 = 0x2F5870A5

local SEED = 0x6765

local function rotr(v, k)
  return (v >> k) | (v << (64 - k))
end

function M.metro64(s, seed, from, len)
  from = from or 1
  len = len or (#s - from + 1)

  local hash = (seed + K2) * K0 + len
  local p = from
  local e = from + len

  if len >= 32 then
    local v0, v1, v2, v3 = hash, hash, hash, hash
    local t
    repeat
      local a, b, c, d = sunpack("<i8i8i8i8", s, p)
      v0 = v0 + a * K0; v0 = rotr(v0, 29) + v2
      v1 = v1 + b * K1; v1 = rotr(v1, 29) + v3
      v2 = v2 + c * K2; v2 = rotr(v2, 29) + v0
      v3 = v3 + d * K3; v3 = rotr(v3, 29) + v1
      p = p + 32
    until p > e - 32

    t = (v0 + v3) * K0 + v1; v2 = v2 ~ (rotr(t, 33) * K1)
    t = (v1 + v2) * K1 + v0; v3 = v3 ~ (rotr(t, 33) * K0)
    t = (v0 + v2) * K0 + v3; v0 = v0 ~ (rotr(t, 33) * K1)
    t = (v1 + v3) * K1 + v2; v1 = v1 ~ (rotr(t, 33) * K0)
    hash = hash + (v0 ~ v1)
  end

  if e - p >= 16 then
    local a, b = sunpack("<i8i8", s, p); p = p + 16
    local v0 = rotr(hash + a * K0, 33) * K1
    local v1 = rotr(hash + b * K1, 33) * K2
    v0 = v0 ~ (rotr(v0 * K0, 35) + v1)
    v1 = v1 ~ (rotr(v1 * K3, 35) + v0)
    hash = hash + v1
  end

  if e - p >= 8 then
    hash = hash + sunpack("<i8", s, p) * K3; p = p + 8
    hash = hash ~ (rotr(hash, 33) * K1)
  end

  if e - p >= 4 then
    hash = hash + sunpack("<I4", s, p) * K3; p = p + 4
    hash = hash ~ (rotr(hash, 15) * K1)
  end

  if e - p >= 2 then
    hash = hash + sunpack("<I2", s, p) * K3; p = p + 2
    hash = hash ~ (rotr(hash, 13) * K1)
  end

  if e - p >= 1 then
    hash = hash + sunpack("<I1", s, p) * K3
    hash = hash ~ (rotr(hash, 25) * K1)
  end

  hash = hash ~ rotr(hash, 33)
  hash = hash * K0
  hash = hash ~ rotr(hash, 33)
  return hash
end

-- the hash over a run of bytes: log bodies and the superblock prefix
function M.bufhash(s, from, len)
  return M.metro64(s, SEED, from, len)
end

-- the hash over a whole block, which is what a block pointer carries
function M.blkhash(s)
  return M.metro64(s, SEED, 1, #s)
end

-- the integer mix gefs uses for its in-memory hash tables. Not on disk,
-- but the deadlist cache keys off it and the shape is worth keeping.
function M.ihash(x)
  x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
  x = (x ~ (x >> 27)) * 0x94d049bb133111eb
  x = x ~ (x >> 31)
  return x & 0xffffffff
end

M.pure = { metro64 = M.metro64, bufhash = M.bufhash, blkhash = M.blkhash }

local ok, native = pcall(require, "gefs.native")
if ok and type(native) == "table" and native.metro64 then
  M.native = {
    metro64 = native.metro64,
    bufhash = function(s, from, len) return native.metro64(s, SEED, from, len) end,
    blkhash = function(s) return native.metro64(s, SEED, 1, #s) end,
  }
  M.metro64, M.bufhash, M.blkhash =
    M.native.metro64, M.native.bufhash, M.native.blkhash
end

return M
