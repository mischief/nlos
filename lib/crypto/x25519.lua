-- X25519, RFC 7748. TweetNaCl's crypto_scalarmult, unchanged in shape.
--
-- This is the Montgomery ladder: 255 iterations, each a fixed sequence of
-- field operations with two constant-time conditional swaps around it, so
-- the work done is independent of the scalar. It is also, by a wide
-- margin, the slowest thing in this library -- see README.

local F = require "crypto.field25519"
local U = require "crypto.util"

local M = {}

local gf, set, A, Z, Mul, S = F.gf, F.set, F.A, F.Z, F.M, F.S
local sel25519, inv25519 = F.sel25519, F.inv25519

local BASE = "\9" .. ("\0"):rep(31)

local function scalarmult(n, p)
  local z = U.zeros(32)
  for i = 0, 30 do z[i] = n[i] end
  z[31] = (n[31] & 127) | 64
  z[0] = z[0] & 248

  local x = gf()
  F.unpack25519(x, p)

  local a, b, c, d = gf(), gf(), gf(), gf()
  local e, f = gf(), gf()
  set(b, x)
  a[0], d[0] = 1, 1

  for i = 254, 0, -1 do
    local r = (z[i >> 3] >> (i & 7)) & 1
    sel25519(a, b, r); sel25519(c, d, r)
    A(e, a, c); Z(a, a, c); A(c, b, d); Z(b, b, d)
    S(d, e); S(f, a); Mul(a, c, a); Mul(c, b, e)
    A(e, a, c); Z(a, a, c); S(b, a); Z(c, d, f)
    Mul(a, c, F._121665); A(a, a, d); Mul(c, c, a); Mul(a, d, f)
    Mul(d, b, x); S(b, e); sel25519(a, b, r); sel25519(c, d, r)
  end

  inv25519(c, c)
  Mul(a, a, c)

  local out = {}
  F.pack25519(out, a)
  return U.frombytes(out, 32)
end

-- Raw scalar multiplication. Both arguments and the result are 32-byte
-- strings.
function M.scalarmult(scalar, point)
  assert(#scalar == 32, "x25519 scalar must be 32 bytes")
  assert(#point == 32, "x25519 point must be 32 bytes")
  return scalarmult(U.tobytes(scalar), U.tobytes(point))
end

function M.scalarmult_base(scalar)
  return M.scalarmult(scalar, BASE)
end

-- The shared secret, with the all-zero result rejected. RFC 7748 leaves
-- that check optional for X25519; SSH's curve25519-sha256 (RFC 8731)
-- requires it, and it costs nothing.
function M.shared(scalar, peer)
  local k = M.scalarmult(scalar, peer)
  if k == ("\0"):rep(32) then return nil, "x25519: degenerate shared secret" end
  return k
end

M.KEY_LEN = 32
M.BASE = BASE

return M
