-- ECDSA on NIST P-256 (secp256r1), verification only.
--
-- What needs it: TLS CertificateVerify. Every public server signs with
-- ECDSA P-256 or with RSA, and a signature over the transcript is what
-- turns a pinned certificate into evidence of who the peer is: a
-- certificate is public and can be replayed, a signature cannot.
--
-- Verification only, and that is a security argument rather than a
-- scope one. Signing needs a secret scalar, a per-signature nonce and
-- constant-time arithmetic to protect both. Nothing here is constant
-- time, because everything here is public: a signature, a public key
-- and a message hash.
--
-- Points are Jacobian, (X, Y, Z) standing for (X/Z^2, Y/Z^3), which
-- keeps a field inversion out of the loop; the one inversion happens at
-- the end. The curve's a is -3, which the doubling formula uses.

local bn = require "crypto.bignum"
local util = require "crypto.util"

local M = {}

local unhex = util.unhex

M.P = unhex "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
M.N = unhex "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
M.B = unhex "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b"
M.GX = unhex "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
M.GY = unhex "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"

local p = assert(bn.modulus(M.P))
local n = assert(bn.modulus(M.N))

-- Everything below works on field elements in Montgomery form.
local function fe(bytes)
  return p:enter(p:from(bytes))
end

local ZERO = p.zero
local ONE = p:enter(p.one)
local B = fe(M.B)

local function fmul(a, b) return p:mulm(a, b) end
local function fsqr(a) return p:mulm(a, a) end
local function fadd(a, b) return p:add(a, b) end
local function fsub(a, b) return p:sub(a, b) end

local function fdouble(a) return fadd(a, a) end

local function is_inf(pt)
  return p:is_zero(pt[3])
end

local INF = { ZERO, ONE, ZERO }

-- Doubling, with a = -3 (the "dbl-2001-b" formulas).
local function double(pt)
  if is_inf(pt) then return INF end
  local X, Y, Z = pt[1], pt[2], pt[3]

  local delta = fsqr(Z)
  local gamma = fsqr(Y)
  local beta = fmul(X, gamma)
  local alpha = fmul(fadd(fadd(fsub(X, delta), fsub(X, delta)), fsub(X, delta)),
                     fadd(X, delta))

  local X3 = fsub(fsqr(alpha), fdouble(fdouble(fdouble(beta))))
  local Z3 = fsub(fsub(fsqr(fadd(Y, Z)), gamma), delta)
  local Y3 = fsub(fmul(alpha, fsub(fdouble(fdouble(beta)), X3)),
                  fdouble(fdouble(fdouble(fsqr(gamma)))))
  return { X3, Y3, Z3 }
end

-- Addition of two Jacobian points ("add-2007-bl").
local function add(a, b)
  if is_inf(a) then return b end
  if is_inf(b) then return a end

  local X1, Y1, Z1 = a[1], a[2], a[3]
  local X2, Y2, Z2 = b[1], b[2], b[3]

  local Z1Z1, Z2Z2 = fsqr(Z1), fsqr(Z2)
  local U1 = fmul(X1, Z2Z2)
  local U2 = fmul(X2, Z1Z1)
  local S1 = fmul(fmul(Y1, Z2), Z2Z2)
  local S2 = fmul(fmul(Y2, Z1), Z1Z1)

  if p:eq(U1, U2) then
    -- The same point, or two points that cancel.
    if not p:eq(S1, S2) then return INF end
    return double(a)
  end

  local H = fsub(U2, U1)
  local I = fsqr(fdouble(H))
  local J = fmul(H, I)
  local r = fdouble(fsub(S2, S1))
  local V = fmul(U1, I)

  local X3 = fsub(fsub(fsqr(r), J), fdouble(V))
  local Y3 = fsub(fmul(r, fsub(V, X3)), fdouble(fmul(S1, J)))
  local Z3 = fmul(fsub(fsub(fsqr(fadd(Z1, Z2)), Z1Z1), Z2Z2), H)
  return { X3, Y3, Z3 }
end

-- The affine x of a point, as field bytes, or nil for the point at
-- infinity. One inversion, at the end, as promised above.
local function affine_x(pt)
  if is_inf(pt) then return nil end
  local zinv = p:enter(p:inv(p:leave(pt[3])))
  local x = fmul(pt[1], fsqr(zinv))
  return p:to_bytes(p:leave(x))
end

-- on_curve(x, y) -> true when y^2 = x^3 - 3x + b. A public key that is
-- not on the curve is not a public key, and accepting one is how an
-- invalid-curve attack starts.
local function on_curve(x, y)
  local x3 = fmul(fsqr(x), x)
  local three_x = fadd(fadd(x, x), x)
  return p:eq(fsqr(y), fadd(fsub(x3, three_x), B))
end

-- point(bytes) -> a Jacobian point from an uncompressed SEC 1 encoding,
-- 0x04 then X then Y. Compressed points are refused rather than
-- decompressed: no TLS peer sends one.
function M.point(bytes)
  if #bytes ~= 65 or bytes:byte(1) ~= 0x04 then
    return nil, "not an uncompressed P-256 point"
  end
  local xb, yb = bytes:sub(2, 33), bytes:sub(34, 65)

  -- Both coordinates must be reduced already: a peer that sends x + p
  -- is describing the same point in a way no encoder produces.
  local xi, yi = p:from(xb), p:from(yb)
  if p:cmp(xi, p.m) >= 0 or p:cmp(yi, p.m) >= 0 then
    return nil, "coordinate is not reduced"
  end

  local x, y = p:enter(xi), p:enter(yi)
  if p:is_zero(x) and p:is_zero(y) then return nil, "point at infinity" end
  if not on_curve(x, y) then return nil, "point is not on the curve" end
  return { x, y, ONE }
end

local G = { fe(M.GX), fe(M.GY), ONE }

-- u1 * G + u2 * Q, by Shamir's trick: one pass over the bits of both
-- scalars, with the four combinations precomputed.
local function double_scalar_mul(u1, u2, Q)
  local table_ = { [0] = INF, G, Q, add(G, Q) }
  local acc = INF
  local started = false

  -- Both scalars arrive as 32 big-endian bytes, most significant
  -- first, which is the order the bits are consumed in.
  for i = 1, 32 do
    local a, b = u1:byte(i), u2:byte(i)
    for bit = 7, 0, -1 do
      if started then acc = double(acc) end
      local idx = (((a >> bit) & 1)) | ((((b >> bit) & 1)) << 1)
      if idx ~= 0 then
        acc = started and add(acc, table_[idx]) or table_[idx]
        started = true
      end
    end
  end
  return acc
end

-- verify(pubkey, hash, r, s) -> true, or false and a reason.
--
--   pubkey  uncompressed SEC 1 point, 65 bytes
--   hash    the message hash, big-endian; SHA-256 output is 32 bytes
--   r, s    the signature, each 32 bytes
--
-- RFC 6979 4.1 and SEC 1 4.1.4.
function M.verify(pubkey, hash, r, s)
  local Q, err = M.point(pubkey)
  if not Q then return false, err end

  local ri, si = n:from(r), n:from(s)
  if not ri or not si then return false, "signature is too long" end
  if n:is_zero(ri) or n:cmp(ri, n.m) >= 0 then return false, "r is out of range" end
  if n:is_zero(si) or n:cmp(si, n.m) >= 0 then return false, "s is out of range" end

  -- The leftmost bits of the hash, up to the order's length. SHA-256
  -- and P-256 are the same width, so this is the whole digest.
  local e = n:reduce(n:from(hash:sub(1, 32)))

  local w = n:inv(si)
  local u1 = n:leave(n:mulm(n:enter(e), n:enter(w)))
  local u2 = n:leave(n:mulm(n:enter(ri), n:enter(w)))

  local R = double_scalar_mul(n:to_bytes(u1, 32), n:to_bytes(u2, 32), Q)
  local x = affine_x(R)
  if not x then return false, "signature does not verify" end

  -- x is a field element and the comparison is modulo the order, so it
  -- is reduced first. p is larger than n, so one subtraction is enough.
  local v = n:reduce(n:from(x))
  if n:cmp(v, ri) ~= 0 then return false, "signature does not verify" end
  return true
end

M.pure = M

-- The C verifier, when it is there. The whole verification crosses,
-- not one field operation: with the multiply alone in C the other half
-- of the time was the interpreter allocating a string per field
-- operation, and the point formulas above are where that happens.
--
-- The Lua stays as the reference the vectors run against, and
-- spec/p256_spec.lua runs the two against each other. Only `verify`
-- moves; `point` is a parser and its error messages are the useful
-- part of it.
local ok, native = pcall(require, "crypto.native")

if ok and type(native) == "table" and native.p256_verify then
  M.native = {}
  for k, v in pairs(M) do M.native[k] = v end

  function M.native.verify(pubkey, hash, r, s)
    if type(pubkey) ~= "string" or type(hash) ~= "string" then
      return false, "bad argument"
    end
    if native.p256_verify(pubkey, hash, r, s) then return true end

    -- The C answers false for everything, and a caller shows that
    -- string to somebody. The checks that name a reason are the cheap
    -- ones -- parsing the key and ranging the signature -- so they run
    -- here rather than the whole verification twice.
    local ok, why = M.point(pubkey)
    if not ok then return false, why end
    if #r ~= 32 or #s ~= 32 then return false, "signature is not 32 bytes" end

    local ri, si = n:from(r), n:from(s)
    if n:is_zero(ri) or n:cmp(ri, n.m) >= 0 then
      return false, "r is out of range"
    end
    if n:is_zero(si) or n:cmp(si, n.m) >= 0 then
      return false, "s is out of range"
    end
    return false, "signature does not verify"
  end

  M.native.pure = M
  M.verify = M.native.verify
end

return M
