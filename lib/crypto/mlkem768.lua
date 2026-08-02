-- ML-KEM-768 encapsulation, FIPS 203.
--
-- An SSH server only ever encapsulates: the client generates the key
-- pair and decapsulates, so KeyGen and Decaps are not here. That is most
-- of the algorithm gone, and all of the parts with a decision in them --
-- no implicit rejection, no re-encryption, no secret-dependent
-- comparison. What is left is arithmetic on public values plus one
-- random 32-byte message.
--
-- ---- why this needs no bignum and no C ----
--
-- Everything is a 16-bit residue mod q = 3329. A product is under 2^24,
-- an accumulated column under 2^32; Lua 5.4 integers hold all of it with
-- room to spare. There is no field element to represent, no inversion,
-- no carry chain -- which makes this markedly easier to get right in Lua
-- than X25519 was, and the reason it is written here rather than lowered
-- to C.
--
-- ---- constants are computed ----
--
-- The 128 NTT twiddle factors are generated at load from zeta = 17 and
-- the bit-reversal the standard specifies, not carried as a table. Same
-- argument as keccak.lua: a mistyped twiddle is a wrong answer with
-- nothing in it to check against, and the generator says why the numbers
-- are what they are.

local keccak = require "crypto.keccak"

local M = {}

local Q = 3329
local N = 256
local K = 3			-- ML-KEM-768
local ETA1, ETA2 = 2, 2
local DU, DV = 10, 4

M.EK_LEN = 384 * K + 32		-- 1184
M.CT_LEN = 32 * (DU * K + DV)	-- 1088
M.SS_LEN = 32

local schar, sbyte, spack = string.char, string.byte, string.pack
local concat = table.concat

--------------------------------------------------------------------------
-- twiddles

-- zeta^BitRev7(i) mod q, for i = 1..127.
local ZETA = {}
-- zeta^(2*BitRev7(i)+1) mod q, for i = 0..127: the base-case multiplier.
local GAMMA = {}

do
  local function brv7(i)
    local r = 0
    for _ = 1, 7 do
      r = (r << 1) | (i & 1)
      i = i >> 1
    end
    return r
  end

  local function powmod(b, e)
    local r = 1
    b = b % Q
    while e > 0 do
      if e & 1 == 1 then r = r * b % Q end
      b = b * b % Q
      e = e >> 1
    end
    return r
  end

  for i = 1, 127 do ZETA[i] = powmod(17, brv7(i)) end
  for i = 0, 127 do GAMMA[i] = powmod(17, 2 * brv7(i) + 1) end
end

--------------------------------------------------------------------------
-- polynomials: plain 1..256 tables of residues

local function polyzero()
  local p = {}
  for i = 1, N do p[i] = 0 end
  return p
end

-- FIPS 203 Algorithm 9. In place.
local function ntt(f)
  local i = 1
  local len = 128

  while len >= 2 do
    local start = 0

    while start < N do
      local z = ZETA[i]

      i = i + 1
      for j = start, start + len - 1 do
        local t = z * f[j + len + 1] % Q

        f[j + len + 1] = (f[j + 1] - t) % Q
        f[j + 1] = (f[j + 1] + t) % Q
      end
      start = start + 2 * len
    end
    len = len // 2
  end
  return f
end

-- FIPS 203 Algorithm 10. In place.
local function inv_ntt(f)
  local i = 127
  local len = 2

  while len <= 128 do
    local start = 0

    while start < N do
      local z = ZETA[i]

      i = i - 1
      for j = start, start + len - 1 do
        local t = f[j + 1]

        f[j + 1] = (t + f[j + len + 1]) % Q
        f[j + len + 1] = z * (f[j + len + 1] - t) % Q
      end
      start = start + 2 * len
    end
    len = len * 2
  end

  for j = 1, N do f[j] = f[j] * 3303 % Q end	-- 128^-1 mod q
  return f
end

-- FIPS 203 Algorithms 11 and 12: h += f * g, in the NTT domain.
local function mul_acc(h, f, g)
  for i = 0, 127 do
    local a0, a1 = f[2 * i + 1], f[2 * i + 2]
    local b0, b1 = g[2 * i + 1], g[2 * i + 2]
    local gam = GAMMA[i]

    h[2 * i + 1] = (h[2 * i + 1] + a0 * b0 + a1 * b1 % Q * gam) % Q
    h[2 * i + 2] = (h[2 * i + 2] + a0 * b1 + a1 * b0) % Q
  end
  return h
end

local function poly_add(a, b)
  for i = 1, N do a[i] = (a[i] + b[i]) % Q end
  return a
end

--------------------------------------------------------------------------
-- sampling

-- FIPS 203 Algorithm 7: rejection sampling to a polynomial already in
-- the NTT domain. The rejection is why keccak's incremental reader
-- exists -- how much XOF output this needs is not known in advance.
local function sample_ntt(seed)
  local rd = keccak.shake128_reader(seed)
  local a = {}
  local j = 0

  while j < N do
    local c = rd(3)
    local c0, c1, c2 = sbyte(c, 1, 3)
    local d1 = c0 + 256 * (c1 % 16)
    local d2 = (c1 // 16) + 16 * c2

    if d1 < Q then
      j = j + 1
      a[j] = d1
    end
    if d2 < Q and j < N then
      j = j + 1
      a[j] = d2
    end
  end
  return a
end

-- FIPS 203 Algorithm 8: centred binomial distribution.
local function sample_cbd(bytes, eta)
  local f = {}
  local nbits = #bytes * 8
  local bits = {}

  for i = 1, #bytes do
    local b = sbyte(bytes, i)

    for k = 0, 7 do
      bits[(i - 1) * 8 + k + 1] = (b >> k) & 1
    end
  end
  assert(nbits == 2 * eta * N, "cbd: wrong input length")

  for i = 0, N - 1 do
    local x, y = 0, 0

    for k = 0, eta - 1 do
      x = x + bits[2 * i * eta + k + 1]
      y = y + bits[2 * i * eta + eta + k + 1]
    end
    f[i + 1] = (x - y) % Q
  end
  return f
end

local function prf(eta, s, b)
  return keccak.shake256(s .. schar(b), 64 * eta)
end

--------------------------------------------------------------------------
-- encode / decode

-- 12-bit coefficients, two per three bytes.
--
-- The `% Q` is FIPS 203's, not a tidy-up: ByteDecode_d reduces modulo q
-- when d is 12 (and modulo 2^d otherwise). It is also the entire
-- mechanism of the modulus check in section 7.2 -- a 12-bit word always
-- round-trips through a 12-bit encoder, so without the reduction
-- ByteEncode(ByteDecode(ek)) == ek for every input and the check is
-- vacuous. With it, any word at or above q comes back different.
local function decode12(s, off)
  local f = {}

  for i = 0, N // 2 - 1 do
    local b0, b1, b2 = sbyte(s, off + 3 * i, off + 3 * i + 2)

    f[2 * i + 1] = ((b0 | (b1 << 8)) & 0xfff) % Q
    f[2 * i + 2] = (((b1 >> 4) | (b2 << 4)) & 0xfff) % Q
  end
  return f
end

local function encode12(f)
  local out = {}

  for i = 0, N // 2 - 1 do
    local a, b = f[2 * i + 1], f[2 * i + 2]

    out[i + 1] = schar(a & 0xff, ((a >> 8) | ((b & 0xf) << 4)) & 0xff,
        (b >> 4) & 0xff)
  end
  return concat(out)
end

-- Compress and pack d-bit values. Rounding is half-up, as the standard
-- says, which is the +q/2 before the divide.
local function compress_encode(f, d)
  local mask = (1 << d) - 1
  local out, n = {}, 0
  local acc, nbits = 0, 0

  for i = 1, N do
    local c = ((f[i] << d) + Q // 2) // Q & mask

    acc = acc | (c << nbits)
    nbits = nbits + d
    while nbits >= 8 do
      n = n + 1
      out[n] = schar(acc & 0xff)
      acc = acc >> 8
      nbits = nbits - 8
    end
  end
  if nbits > 0 then
    n = n + 1
    out[n] = schar(acc & 0xff)
  end
  return concat(out)
end

--------------------------------------------------------------------------
-- the encapsulation key check, FIPS 203 section 7.2

-- Returns the decoded t-hat vector and rho, or nil plus a reason.
--
-- The modulus check is not decoration: an ek whose 12-bit words are not
-- all below q does not round-trip through ByteEncode, and accepting one
-- would mean encapsulating to a key that no honest party could have
-- produced.
function M.check_ek(ek)
  if type(ek) ~= "string" or #ek ~= M.EK_LEN then
    return nil, "ml-kem: encapsulation key must be " .. M.EK_LEN .. " bytes"
  end

  local that = {}

  for i = 0, K - 1 do
    local off = 384 * i + 1
    local f = decode12(ek, off)

    if encode12(f) ~= ek:sub(off, off + 383) then
      return nil, "ml-kem: encapsulation key fails the modulus check"
    end
    that[i + 1] = f
  end

  return that, ek:sub(384 * K + 1)
end

--------------------------------------------------------------------------
-- K-PKE.Encrypt, FIPS 203 Algorithm 14

local function pke_encrypt(that, rho, m, r)
  -- A-hat[i][j] = SampleNTT(rho || j || i): j is the column and it
  -- comes FIRST, which is the easiest line in this file to get backwards.
  local ahat = {}

  for i = 0, K - 1 do
    ahat[i + 1] = {}
    for j = 0, K - 1 do
      ahat[i + 1][j + 1] = sample_ntt(rho .. schar(j) .. schar(i))
    end
  end

  local nonce = 0
  local y, e1 = {}, {}

  for i = 1, K do
    y[i] = sample_cbd(prf(ETA1, r, nonce), ETA1)
    nonce = nonce + 1
  end
  for i = 1, K do
    e1[i] = sample_cbd(prf(ETA2, r, nonce), ETA2)
    nonce = nonce + 1
  end
  local e2 = sample_cbd(prf(ETA2, r, nonce), ETA2)

  for i = 1, K do ntt(y[i]) end

  -- u = NTT^-1(A-hat^T . y-hat) + e1, so column i of A sums over rows.
  local u = {}

  for i = 1, K do
    local acc = polyzero()

    for j = 1, K do
      mul_acc(acc, ahat[j][i], y[j])
    end
    u[i] = poly_add(inv_ntt(acc), e1[i])
  end

  -- v = NTT^-1(t-hat^T . y-hat) + e2 + Decompress_1(m)
  local vacc = polyzero()

  for i = 1, K do
    mul_acc(vacc, that[i], y[i])
  end
  local v = poly_add(inv_ntt(vacc), e2)

  for i = 0, N - 1 do
    local bit = (sbyte(m, i // 8 + 1) >> (i % 8)) & 1

    v[i + 1] = (v[i + 1] + bit * ((Q + 1) // 2)) % Q
  end

  local c1 = {}

  for i = 1, K do c1[i] = compress_encode(u[i], DU) end

  return concat(c1) .. compress_encode(v, DV)
end

--------------------------------------------------------------------------
-- ML-KEM.Encaps, FIPS 203 Algorithm 20

-- encaps(ek, rand) -> ciphertext, shared secret
--
-- `rand` is a function returning n random bytes, the same shape every
-- other module here takes, so this never reaches for entropy itself.
function M.encaps(ek, rand)
  local that, rho = M.check_ek(ek)

  if not that then return nil, rho end

  local m = rand(32)
  local g = keccak.sha3_512(m .. keccak.sha3_256(ek))
  local shared, r = g:sub(1, 32), g:sub(33, 64)

  return pke_encrypt(that, rho, m, r), shared
end

return M
