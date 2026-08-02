-- SHA-512, FIPS 180-4. Ed25519 is defined in terms of it; nothing else
-- here uses it.
--
-- The 64-bit case is the easy one in Lua 5.4: integer arithmetic is
-- exactly 64-bit two's complement and wraps around on overflow, which is
-- the modular addition SHA-512 wants, so no masking is needed at all.
-- `>>` is logical, so the rotate below is a true 64-bit rotate.

local hashstate = require "crypto.hashstate"

local spack, sunpack = string.pack, string.unpack

local K = {
  0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
  0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
  0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
  0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
  0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
  0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
  0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
  0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
  0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
  0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
  0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
  0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
  0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
  0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
  0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
  0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
  0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
  0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
  0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
  0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
}

local function rotr(x, n)
  return (x >> n) | (x << (64 - n))
end

local w = {}

local function block(h, s, off)
  for i = 1, 16 do
    w[i] = sunpack(">i8", s, off + (i - 1) * 8)
  end
  for i = 17, 80 do
    local a, b = w[i - 15], w[i - 2]
    local s0 = rotr(a, 1) ~ rotr(a, 8) ~ (a >> 7)
    local s1 = rotr(b, 19) ~ rotr(b, 61) ~ (b >> 6)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  end

  local a, b, c, d, e, f, g, hh =
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]

  for i = 1, 80 do
    local S1 = rotr(e, 14) ~ rotr(e, 18) ~ rotr(e, 41)
    local ch = (e & f) ~ (~e & g)
    local t1 = hh + S1 + ch + K[i] + w[i]
    local S0 = rotr(a, 28) ~ rotr(a, 34) ~ rotr(a, 39)
    local maj = (a & b) ~ (a & c) ~ (b & c)
    local t2 = S0 + maj
    hh, g, f, e, d, c, b, a = g, f, e, d + t1, c, b, a, t1 + t2
  end

  h[1] = h[1] + a
  h[2] = h[2] + b
  h[3] = h[3] + c
  h[4] = h[4] + d
  h[5] = h[5] + e
  h[6] = h[6] + f
  h[7] = h[7] + g
  h[8] = h[8] + hh
end

local spec = {
  block_len = 128,
  digest_len = 64,
  -- SHA-512's length field is 128 bits wide; hashstate zero-fills the top
  -- half, which is right for any message Lua can hold.
  len_bytes = 16,
  compress = block,

  initial = function()
    return { 0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b,
             0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f,
             0x1f83d9abfb41bd6b, 0x5be0cd19137e2179 }
  end,

  enclen = function(bits) return spack(">i8", bits) end,

  encode = function(h)
    return spack(">i8i8i8i8i8i8i8i8", h[1], h[2], h[3], h[4],
                 h[5], h[6], h[7], h[8])
  end,
}

--------------------------------------------------------------------------

-- The C compression function, when it is there; see the note in
-- ssh/crypto/sha256.lua. SHA-512 gets it too because Ed25519 hashes with
-- it twice per signature, and because a 64-bit hash is where a 64-bit
-- host is furthest ahead of an interpreter.
local M = hashstate.define(spec)
M.pure = M

local ok, native = pcall(require, "crypto.native")
if ok and type(native) == "table" and native.sha512_blocks then
  local sha512_blocks = native.sha512_blocks
  local encode = spec.encode

  local fast = {}
  for k, v in pairs(spec) do fast[k] = v end
  fast.blocks = function(h, s, from, nblocks)
    local st = sha512_blocks(encode(h),
                             s:sub(from, from + nblocks * 128 - 1))
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8] =
      sunpack(">i8i8i8i8i8i8i8i8", st)
  end

  M = hashstate.define(fast)
  M.pure = hashstate.define(spec)
  M.native = M
end

return M
