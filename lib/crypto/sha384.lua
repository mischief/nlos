-- SHA-384, FIPS 180-4.
--
-- SHA-512 with another initial state and the digest cut to its first
-- six words. Everything else -- the compression function, the block
-- size, the 128-bit length field, the C backend -- is SHA-512's, and
-- this file borrows it rather than repeating it.
--
-- What needs it: TLS 1.3 signature algorithms. A server that picks
-- rsa_pss_rsae_sha384 is otherwise a server this tree cannot talk to.

local hashstate = require "crypto.hashstate"
local sha512 = require "crypto.sha512"

local spack = string.pack

-- FIPS 180-4 5.3.4: the fractional parts of the square roots of the
-- 9th through 16th primes, where SHA-512 takes the first eight.
local function initial()
  return { 0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17,
           0x152fecd8f70e5939, 0x67332667ffc00b31, 0x8eb44a8768581511,
           0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4 }
end

-- The digest is the first six words. The other two are state and are
-- discarded, which is the whole of the truncation: a length-extension
-- attack needs them and does not get them.
local function encode(h)
  return spack(">i8i8i8i8i8i8", h[1], h[2], h[3], h[4], h[5], h[6])
end

local function variant(base)
  local spec = {}
  for k, v in pairs(base) do spec[k] = v end
  spec.digest_len = 48
  spec.initial = initial
  spec.encode = encode
  -- `blocks`, when SHA-512 has a C one, serialises the state with
  -- SHA-512's own encoder. That is the full eight words and is right:
  -- only the digest is truncated, never the state.
  return hashstate.define(spec)
end

local M = variant(sha512.spec)

M.pure = variant(sha512.spec_pure)
if sha512.native then M.native = M end

return M
