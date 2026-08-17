-- SHA-1, FIPS 180-4, for the one job that still needs it: RFC 6455's
-- handshake, where an endpoint proves it read the request by hashing
-- the peer's key with a fixed GUID.
--
-- Not for signatures. SHA-1 is broken for anything that has to be
-- unforgeable, so a second caller needs an argument, not a require.

local hashstate = require "crypto.hashstate"

local MASK = 0xffffffff
local spack, sunpack = string.pack, string.unpack

local function rol(x, n)
  return ((x << n) | (x >> (32 - n))) & MASK
end

local w = {}

local function block(h, s, off)
  for i = 1, 16 do
    w[i] = sunpack(">I4", s, off + (i - 1) * 4)
  end
  for i = 17, 80 do
    w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
  end

  local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

  for i = 1, 80 do
    local f, k
    if i <= 20 then
      f = (b & c) | ((~b & MASK) & d)
      k = 0x5a827999
    elseif i <= 40 then
      f = b ~ c ~ d
      k = 0x6ed9eba1
    elseif i <= 60 then
      f = (b & c) | (b & d) | (c & d)
      k = 0x8f1bbcdc
    else
      f = b ~ c ~ d
      k = 0xca62c1d6
    end

    local t = (rol(a, 5) + f + e + k + w[i]) & MASK
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end

  h[1] = (h[1] + a) & MASK
  h[2] = (h[2] + b) & MASK
  h[3] = (h[3] + c) & MASK
  h[4] = (h[4] + d) & MASK
  h[5] = (h[5] + e) & MASK
end

local spec = {
  block_len = 64,
  digest_len = 20,
  len_bytes = 8,
  compress = block,

  initial = function()
    return { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 }
  end,

  enclen = function(bits) return spack(">I8", bits) end,

  encode = function(h)
    return spack(">I4I4I4I4I4", h[1], h[2], h[3], h[4], h[5])
  end,
}

-- No C backend: the one caller hashes 60 bytes once per connection.
local M = hashstate.define(spec)
M.pure = M

return M
