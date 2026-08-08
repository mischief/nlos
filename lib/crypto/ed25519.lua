-- Ed25519, RFC 8032. TweetNaCl's crypto_sign / crypto_sign_open, with the
-- signature detached rather than prefixed to the message, which is the
-- form SSH uses.
--
-- Signing needs no randomness: the per-signature nonce is the hash of the
-- key's second half with the message, which is what makes this safe to
-- run on a machine whose entropy source is still being argued about.

local F = require "crypto.field25519"
local sha512 = require "crypto.sha512"
local U = require "crypto.util"

local M = {}

local gf, set, A, Z, Mul, S = F.gf, F.set, F.A, F.Z, F.M, F.S
local inv25519, pow2523 = F.inv25519, F.pow2523

-- Order of the base point, little-endian bytes.
local L = { [0] =
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
  0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
}

local function point()
  return { gf(), gf(), gf(), gf() }
end

-- Extended-coordinate addition on the twisted Edwards curve.
local function add(p, q)
  local a, b, c, d = gf(), gf(), gf(), gf()
  local tt, e, f, g, h = gf(), gf(), gf(), gf(), gf()

  Z(a, p[2], p[1])
  Z(tt, q[2], q[1])
  Mul(a, a, tt)
  A(b, p[1], p[2])
  A(tt, q[1], q[2])
  Mul(b, b, tt)
  Mul(c, p[4], q[4])
  Mul(c, c, F.D2)
  Mul(d, p[3], q[3])
  A(d, d, d)
  Z(e, b, a)
  Z(f, d, c)
  A(g, d, c)
  A(h, b, a)

  Mul(p[1], e, f)
  Mul(p[2], h, g)
  Mul(p[3], g, f)
  Mul(p[4], e, h)
end

local function cswap(p, q, b)
  for i = 1, 4 do F.sel25519(p[i], q[i], b) end
end

local function pack(p)
  local tx, ty, zi = gf(), gf(), gf()
  inv25519(zi, p[3])
  Mul(tx, p[1], zi)
  Mul(ty, p[2], zi)
  local r = {}
  F.pack25519(r, ty)
  r[31] = r[31] ~ (F.par25519(tx) << 7)
  return r
end

local function scalarmult(p, q, s)
  set(p[1], F.gf0); set(p[2], F.gf1); set(p[3], F.gf1); set(p[4], F.gf0)
  for i = 255, 0, -1 do
    local b = (s[i >> 3] >> (i & 7)) & 1
    cswap(p, q, b)
    add(q, p)
    add(p, p)
    cswap(p, q, b)
  end
end

local function scalarbase(p, s)
  local q = point()
  set(q[1], F.X); set(q[2], F.Y); set(q[3], F.gf1)
  Mul(q[4], F.X, F.Y)
  scalarmult(p, q, s)
end

-- x mod L, where x is a 64-limb little-endian value. TweetNaCl's modL,
-- with C's arithmetic shifts written as floor division: x can be negative
-- here and a logical shift would be silently wrong.
local function modL(r, x)
  for i = 63, 32, -1 do
    local carry = 0
    local j = i - 32
    while j < i - 12 do
      x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32)]
      carry = (x[j] + 128) // 256
      x[j] = x[j] - carry * 256
      j = j + 1
    end
    x[j] = x[j] + carry
    x[i] = 0
  end

  local carry = 0
  for j = 0, 31 do
    x[j] = x[j] + carry - (x[31] // 16) * L[j]
    carry = x[j] // 256
    x[j] = x[j] & 255
  end
  for j = 0, 31 do x[j] = x[j] - carry * L[j] end
  for i = 0, 31 do
    x[i + 1] = x[i + 1] + (x[i] // 256)
    r[i] = x[i] & 255
  end
end

-- Reduce a 64-byte hash to a scalar, in place over a 0-based byte table.
local function reduce(r)
  local x = {}
  for i = 0, 63 do x[i] = r[i] end
  for i = 0, 63 do r[i] = 0 end
  modL(r, x)
end

-- Decompress a public key to -P. TweetNaCl negates here so that
-- verification can use a single addition.
local function unpackneg(r, pk)
  local tt, chk, num, den = gf(), gf(), gf(), gf()
  local den2, den4, den6 = gf(), gf(), gf()

  set(r[3], F.gf1)
  F.unpack25519(r[2], pk)
  S(num, r[2])
  Mul(den, num, F.D)
  Z(num, num, r[3])
  A(den, r[3], den)

  S(den2, den)
  S(den4, den2)
  Mul(den6, den4, den2)
  Mul(tt, den6, num)
  Mul(tt, tt, den)

  pow2523(tt, tt)
  Mul(tt, tt, num)
  Mul(tt, tt, den)
  Mul(tt, tt, den)
  Mul(r[1], tt, den)

  S(chk, r[1])
  Mul(chk, chk, den)
  if F.neq25519(chk, num) then Mul(r[1], r[1], F.I) end

  S(chk, r[1])
  Mul(chk, chk, den)
  if F.neq25519(chk, num) then return false end

  if F.par25519(r[1]) == (pk[31] >> 7) then Z(r[1], F.gf0, r[1]) end

  Mul(r[4], r[1], r[2])
  return true
end

-- Expand a 32-byte seed into the clamped scalar and the prefix.
local function expand(seed)
  local d = U.tobytes(sha512.hash(seed))
  d[0] = d[0] & 248
  d[31] = (d[31] & 127) | 64
  return d
end

-- Public key from a 32-byte seed. OpenSSH's "private key" file holds the
-- seed and the public key together; this derives the second from the first.
function M.publickey(seed)
  assert(#seed == 32, "ed25519 seed must be 32 bytes")
  local d = expand(seed)
  local p = point()
  scalarbase(p, d)
  return U.frombytes(pack(p), 32)
end

function M.keypair(seed)
  return M.publickey(seed), seed
end

-- Detached signature over `msg`, 64 bytes.
function M.sign(seed, msg)
  assert(#seed == 32, "ed25519 seed must be 32 bytes")
  local d = expand(seed)
  local prefix = U.frombytes(d, 64):sub(33, 64)
  local pk = M.publickey(seed)

  local r = U.tobytes(sha512.hash(prefix .. msg))
  reduce(r)

  local p = point()
  scalarbase(p, r)
  local Rs = U.frombytes(pack(p), 32)

  local h = U.tobytes(sha512.hash(Rs .. pk .. msg))
  reduce(h)

  local x = {}
  for i = 0, 63 do x[i] = 0 end
  for i = 0, 31 do x[i] = r[i] end
  for i = 0, 31 do
    for j = 0, 31 do x[i + j] = x[i + j] + h[i] * d[j] end
  end

  local sbytes = {}
  modL(sbytes, x)

  return Rs .. U.frombytes(sbytes, 32)
end

-- Verify a detached signature. Returns a boolean and never raises on
-- malformed input: this runs on data an unauthenticated peer chose.
function M.verify(pk, msg, sig)
  if type(pk) ~= "string" or #pk ~= 32 then return false end
  if type(sig) ~= "string" or #sig ~= 64 then return false end

  local q = point()
  if not unpackneg(q, U.tobytes(pk)) then return false end

  -- S must be canonical: a non-reduced scalar would make signatures
  -- malleable, which SSH does not care about but callers might.
  local s = U.tobytes(sig:sub(33, 64))
  for i = 31, 0, -1 do
    if s[i] > L[i] then return false end
    if s[i] < L[i] then break end
    if i == 0 then return false end
  end

  local h = U.tobytes(sha512.hash(sig:sub(1, 32) .. pk .. msg))
  reduce(h)

  local p = point()
  scalarmult(p, q, h)
  local q2 = point()
  scalarbase(q2, s)
  add(p, q2)

  return U.ct_eq(sig:sub(1, 32), U.frombytes(pack(p), 32))
end

M.SEED_LEN = 32
M.PUBLIC_LEN = 32
M.SIG_LEN = 64
M.pure = M

-- The C signer, when it is there. Same bargain as x25519 and the
-- hashes: the Lua is the reference the vectors run against and the only
-- implementation on a build without the module. Verification is two
-- scalar multiplications, and every connection pays for one signature.
--
-- M is never reassigned, for the reason crypto/x25519.lua gives:
-- keypair and sign reach publickey through the upvalue, so pointing M
-- at the fast table would leave nothing that is actually the pure
-- implementation for the spec to compare against.
--
-- verify keeps the contract of never raising on a malformed key or
-- signature, because it runs on data an unauthenticated peer chose. The
-- C side answers false for a wrong length rather than erroring, so the
-- two agree there as well as on the arithmetic.
local fast = nil
local ok, native = pcall(require, "crypto.native")

if ok and type(native) == "table" and native.ed25519_sign then
  fast = {}
  for k, v in pairs(M) do fast[k] = v end

  function fast.publickey(seed)
    assert(#seed == 32, "ed25519 seed must be 32 bytes")
    return native.ed25519_publickey(seed)
  end

  function fast.keypair(seed)
    return fast.publickey(seed), seed
  end

  function fast.sign(seed, msg)
    assert(#seed == 32, "ed25519 seed must be 32 bytes")
    return native.ed25519_sign(seed, msg)
  end

  function fast.verify(pk, msg, sig)
    if type(pk) ~= "string" or type(msg) ~= "string" then return false end
    if type(sig) ~= "string" then return false end
    return native.ed25519_verify(pk, msg, sig)
  end

  fast.pure = M
  fast.native = fast
  M.native = fast
end

return fast or M
