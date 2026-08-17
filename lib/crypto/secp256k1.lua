-- secp256k1 and BIP 340 Schnorr signatures, for nostr. Keys are x-only:
-- 32 bytes naming the even-Y point with that x, and so is a signature's
-- R. Points are Jacobian, as in p256, but a is 0 here.

-- Signing is here, which nothing else in this tree does, and it is not
-- constant time: the scalar multiplication branches on the bits of the
-- secret. BIP 340 derives the nonce from the key and the message, so a
-- repeat cannot leak the key as an ECDSA nonce does. Anyone who can time
-- this locally still can. That is a handheld, not a server.

local bn = require "crypto.bignum"
local sha256 = require "crypto.sha256"
local util = require "crypto.util"

local M = {}

local unhex = util.unhex
local byte, char, rep, sub = string.byte, string.char, string.rep, string.sub

M.P = unhex "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"
M.N = unhex "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
M.B = unhex "0000000000000000000000000000000000000000000000000000000000000007"
M.GX = unhex "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
M.GY = unhex "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

local p = assert(bn.modulus(M.P))
local n = assert(bn.modulus(M.N))

-- (p + 1) / 4, the exponent that takes a square root: p is 3 mod 4.
local SQRTE = unhex "3fffffffffffffffffffffffffffffffffffffffffffffffffffffffbfffff0c"

local function fe(bytes) return p:enter(p:from(bytes)) end

local ZERO = p.zero
local ONE = p:enter(p.one)
local B = fe(M.B)

local function fmul(a, b) return p:mulm(a, b) end
local function fsqr(a) return p:mulm(a, a) end
local function fadd(a, b) return p:add(a, b) end
local function fsub(a, b) return p:sub(a, b) end
local function fdouble(a) return fadd(a, a) end

local INF = { ZERO, ONE, ZERO }

local function is_inf(pt) return p:is_zero(pt[3]) end

-- Doubling with a = 0 ("dbl-2009-l"). This is where secp256k1 parts
-- company with P-256, whose formula folds in a = -3.
local function double(pt)
  if is_inf(pt) then return INF end
  local X, Y, Z = pt[1], pt[2], pt[3]

  local A = fsqr(X)
  local Bb = fsqr(Y)
  local C = fsqr(Bb)
  local D = fdouble(fsub(fsub(fsqr(fadd(X, Bb)), A), C))
  local E = fadd(fdouble(A), A)
  local F = fsqr(E)

  local X3 = fsub(F, fdouble(D))
  local Y3 = fsub(fmul(E, fsub(D, X3)), fdouble(fdouble(fdouble(C))))
  local Z3 = fdouble(fmul(Y, Z))
  return { X3, Y3, Z3 }
end

-- Addition of two Jacobian points ("add-2007-bl"), which does not care
-- what a is.
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

local function negate(pt)
  if is_inf(pt) then return pt end
  return { pt[1], p:sub(ZERO, pt[2]), pt[3] }
end

-- The affine coordinates, as field bytes, or nil for infinity.
local function affine(pt)
  if is_inf(pt) then return nil end
  local zinv = p:enter(p:inv(p:leave(pt[3])))
  local z2 = fsqr(zinv)
  local x = fmul(pt[1], z2)
  local y = fmul(pt[2], fmul(z2, zinv))
  return p:to_bytes(p:leave(x), 32), p:to_bytes(p:leave(y), 32)
end

local G = { fe(M.GX), fe(M.GY), ONE }

-- k * pt, most significant bit first. Not constant time, as the header
-- says: the branch below is on a bit of the scalar, and for `sign` that
-- scalar is secret.
local function mul(k, pt)
  local acc, started = INF, false
  for i = 1, #k do
    local b = byte(k, i)
    for bit = 7, 0, -1 do
      if started then acc = double(acc) end
      if (b >> bit) & 1 == 1 then
        acc = started and add(acc, pt) or pt
        started = true
      end
    end
  end
  return acc
end

-- u1 * G + u2 * Q by Shamir's trick, which is what verification wants.
local function double_scalar_mul(u1, u2, Q)
  local tbl = { [0] = INF, G, Q, add(G, Q) }
  local acc, started = INF, false
  for i = 1, 32 do
    local a, b = byte(u1, i), byte(u2, i)
    for bit = 7, 0, -1 do
      if started then acc = double(acc) end
      local idx = ((a >> bit) & 1) | (((b >> bit) & 1) << 1)
      if idx ~= 0 then
        acc = started and add(acc, tbl[idx]) or tbl[idx]
        started = true
      end
    end
  end
  return acc
end

--------------------------------------------------------------------------
-- x-only points

-- lift_x(x) -> the point with that x and an even y, or nil plus a
-- reason. BIP 340 3: half the 32-byte strings are not an x at all, and
-- of those that are, the even-Y point is the one a key names.
function M.lift_x(xb)
  if #xb ~= 32 then return nil, "x is not 32 bytes" end
  local xi = p:from(xb)
  if not xi or p:cmp(xi, p.m) >= 0 then return nil, "x is not a field element" end

  local x = p:enter(xi)
  local c = p:leave(fadd(fmul(fsqr(x), x), B))
  local y = p:enter(p:exp(c, SQRTE))
  if not p:eq(fsqr(y), p:enter(c)) then return nil, "x is not on the curve" end

  -- The even root. y and p - y differ in the last bit, p being odd.
  if byte(p:to_bytes(p:leave(y), 32), 32) & 1 == 1 then
    y = p:sub(ZERO, y)
  end
  return { x, y, ONE }
end

--------------------------------------------------------------------------
-- BIP 340

-- SHA256(SHA256(tag) || SHA256(tag) || msg). The doubled prefix is a
-- whole block, so a tag costs one compression and cannot collide with
-- an unprefixed hash of anything.
local tags = {}
local function tagged(tag, msg)
  local prefix = tags[tag]
  if not prefix then
    local h = sha256.hash(tag)
    prefix = h .. h
    tags[tag] = prefix
  end
  return sha256.hash(prefix .. msg)
end

M.tagged_hash = tagged

local function scalar(bytes)
  return n:reduce(n:from(bytes))
end

local function nmul(a, b)
  return n:leave(n:mulm(n:enter(a), n:enter(b)))
end

-- pubkey(sec) -> the 32-byte x-only public key, or nil plus a reason.
function M.pubkey(sec)
  if #sec ~= 32 then return nil, "secret key is not 32 bytes" end
  local d = n:from(sec)
  if n:is_zero(d) or n:cmp(d, n.m) >= 0 then
    return nil, "secret key is out of range"
  end
  local x = affine(mul(sec, G))
  return x
end

-- The secret in the form BIP 340 signs with: the scalar whose public
-- point has an even y, and that point's x.
local function seckey(sec)
  local d0 = n:from(sec)
  if not d0 or n:is_zero(d0) or n:cmp(d0, n.m) >= 0 then
    return nil, "secret key is out of range"
  end
  local P = mul(sec, G)
  local px, py = affine(P)
  local d = d0
  if byte(py, 32) & 1 == 1 then d = n:sub(n.zero, d0) end
  return d, px
end

-- sign(sec, msg, aux) -> 64 bytes, or nil plus a reason.
--
--   aux   32 bytes of fresh randomness. BIP 340 allows it to be absent
--         and the signature is still safe against nonce reuse; what it
--         defends against is a fault or a side channel that leaks the
--         nonce, so a caller with entropy should pass it.
--
-- The signature is verified before it is returned, which BIP 340 5
-- recommends: a faulty multiplication that produced a bad signature
-- would otherwise leak the key to whoever collected it.
function M.sign(sec, msg, aux, opts)
  if type(sec) ~= "string" or #sec ~= 32 then
    return nil, "secret key is not 32 bytes"
  end
  local d, px = seckey(sec)
  if not d then return nil, px end

  aux = aux or rep("\0", 32)
  if #aux ~= 32 then return nil, "aux is not 32 bytes" end

  local t = tagged("BIP0340/aux", aux)
  local mask = {}
  for i = 1, 32 do mask[i] = char(byte(d, i) ~ byte(t, i)) end
  local rand = tagged("BIP0340/nonce", table.concat(mask) .. px .. msg)

  local k0 = scalar(rand)
  if n:is_zero(k0) then return nil, "nonce is zero" end

  local R = mul(k0, G)
  local rx, ry = affine(R)
  local k = k0
  if byte(ry, 32) & 1 == 1 then k = n:sub(n.zero, k0) end

  local e = scalar(tagged("BIP0340/challenge", rx .. px .. msg))
  local s = n:add(k, nmul(e, d))
  local sig = rx .. n:to_bytes(s, 32)

  if not (opts and opts.check == false) then
    local ok, why = M.verify(px, msg, sig)
    if not ok then return nil, why or "the signature did not verify" end
  end
  return sig
end

-- verify(pubkey, msg, sig) -> true, or false and a reason. BIP 340 4.2.
function M.verify(pubkey, msg, sig)
  if type(pubkey) ~= "string" or #pubkey ~= 32 then
    return false, "public key is not 32 bytes"
  end
  if type(sig) ~= "string" or #sig ~= 64 then
    return false, "signature is not 64 bytes"
  end

  local P, err = M.lift_x(pubkey)
  if not P then return false, err end

  local r, s = sub(sig, 1, 32), sub(sig, 33, 64)
  if p:cmp(p:from(r), p.m) >= 0 then return false, "r is not a field element" end
  local si = n:from(s)
  if n:cmp(si, n.m) >= 0 then return false, "s is out of range" end

  local e = scalar(tagged("BIP0340/challenge", r .. pubkey .. msg))

  -- s * G - e * P, with the subtraction done as an addition of -P.
  local R = double_scalar_mul(n:to_bytes(si, 32), n:to_bytes(e, 32), negate(P))
  local rx, ry = affine(R)
  if not rx then return false, "R is the point at infinity" end
  if byte(ry, 32) & 1 == 1 then return false, "R has an odd y" end
  if rx ~= r then return false, "signature does not verify" end
  return true
end

--------------------------------------------------------------------------
-- ECDH, for NIP-44: the x coordinate of the shared point, which is what
-- nostr hands to HKDF. The peer's key is x-only, so this is the even-Y
-- point's x and both ends compute the same thing.
function M.shared_x(sec, pubkey)
  if type(sec) ~= "string" or #sec ~= 32 then
    return nil, "secret key is not 32 bytes"
  end
  local d = n:from(sec)
  if not d or n:is_zero(d) or n:cmp(d, n.m) >= 0 then
    return nil, "secret key is out of range"
  end
  local P, err = M.lift_x(pubkey)
  if not P then return nil, err end

  local S = mul(sec, P)
  local x = affine(S)
  if not x then return nil, "shared point is the point at infinity" end
  return x
end

-- The C, when it is there. Only the three scalar multiplications move:
-- the tagged hashes, the nonce and every length check stay here, so the
-- vectors run over the same code either way and `pure` keeps naming the
-- Lua that spec/secp256k1_spec.lua compares against.
local lua_impl = {
  pubkey = M.pubkey, sign = M.sign, verify = M.verify, shared_x = M.shared_x,
}
M.pure = M

local ok, native = pcall(require, "crypto.native")
if ok and type(native) == "table" and native.secp256k1_verify then
  M.native = {}
  for k, v in pairs(M) do M.native[k] = v end

  -- The point of a secret scalar: x and y, or nil for a scalar that is
  -- not a key.
  local function mul_g(sec)
    local xy = native.secp256k1_mul_g(sec)
    if not xy then return nil end
    return sub(xy, 1, 32), sub(xy, 33, 64)
  end

  function M.native.pubkey(sec)
    if type(sec) ~= "string" or #sec ~= 32 then
      return nil, "secret key is not 32 bytes"
    end
    local x = mul_g(sec)
    if not x then return nil, "secret key is out of range" end
    return x
  end

  function M.native.sign(sec, msg, aux, opts)
    if type(sec) ~= "string" or #sec ~= 32 then
      return nil, "secret key is not 32 bytes"
    end
    local px, py = mul_g(sec)
    if not px then return nil, "secret key is out of range" end

    aux = aux or rep("\0", 32)
    if #aux ~= 32 then return nil, "aux is not 32 bytes" end

    -- The scalar whose point has an even y, as BIP 340 signs with.
    local d = n:from(sec)
    if byte(py, 32) & 1 == 1 then d = n:sub(n.zero, d) end

    local t = tagged("BIP0340/aux", aux)
    local mask = {}
    for i = 1, 32 do mask[i] = char(byte(d, i) ~ byte(t, i)) end
    local k0 = scalar(tagged("BIP0340/nonce",
                             table.concat(mask) .. px .. msg))
    if n:is_zero(k0) then return nil, "nonce is zero" end

    local rx, ry = mul_g(n:to_bytes(k0, 32))
    local k = k0
    if byte(ry, 32) & 1 == 1 then k = n:sub(n.zero, k0) end

    local e = scalar(tagged("BIP0340/challenge", rx .. px .. msg))
    local sig = rx .. n:to_bytes(n:add(k, nmul(e, d)), 32)

    if not (opts and opts.check == false) then
      local good, why = M.native.verify(px, msg, sig)
      if not good then return nil, why or "the signature did not verify" end
    end
    return sig
  end

  function M.native.verify(pubkey, msg, sig)
    if type(pubkey) ~= "string" or #pubkey ~= 32 then
      return false, "public key is not 32 bytes"
    end
    if type(sig) ~= "string" or #sig ~= 64 then
      return false, "signature is not 64 bytes"
    end
    local r, s = sub(sig, 1, 32), sub(sig, 33, 64)
    local e = scalar(tagged("BIP0340/challenge", r .. pubkey .. msg))
    if native.secp256k1_verify(pubkey, n:to_bytes(e, 32), r, s) then
      return true
    end

    -- The C answers false for everything and a caller shows the reason
    -- to somebody, so the cheap checks that name one run here rather
    -- than the whole verification twice.
    local P, why = M.lift_x(pubkey)
    if not P then return false, why end
    if p:cmp(p:from(r), p.m) >= 0 then return false, "r is not a field element" end
    if n:cmp(n:from(s), n.m) >= 0 then return false, "s is out of range" end
    return false, "signature does not verify"
  end

  function M.native.shared_x(sec, pubkey)
    if type(sec) ~= "string" or #sec ~= 32 then
      return nil, "secret key is not 32 bytes"
    end
    if type(pubkey) ~= "string" or #pubkey ~= 32 then
      return nil, "public key is not 32 bytes"
    end
    local x = native.secp256k1_ecdh(sec, pubkey)
    if x then return x end
    local P, why = M.lift_x(pubkey)
    if not P then return nil, why end
    return nil, "secret key is out of range"
  end

  M.pure = setmetatable(lua_impl, { __index = M })
  M.pubkey, M.sign = M.native.pubkey, M.native.sign
  M.verify, M.shared_x = M.native.verify, M.native.shared_x
end

return M
