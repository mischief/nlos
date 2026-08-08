-- Modular arithmetic over a fixed modulus, in Montgomery form.
--
-- What needs it: ECDSA over P-256, and RSA signature verification. Both
-- verify public values, so nothing here is written to be constant time
-- and nothing here may hold a secret. X25519 and Ed25519 do hold
-- secrets and use crypto/field25519.lua instead, which is written
-- for one prime and is branch-free.
--
-- A number is a big-endian byte string, always the modulus's own
-- length rounded up to a multiple of four. Strings rather than limb
-- tables because a table cannot cross into C without being taken apart
-- limb by limb, and `mulm` is the one function worth writing in C: a
-- P-256 verification is a few thousand of them and almost nothing
-- else.
--
-- The limbs are 32 bits, and Lua 5.4 handles them exactly. A product of
-- two limbs plus two carries is at most 2^64 - 1, which is the whole
-- 64-bit range: the arithmetic wraps rather than overflows, `>>` is
-- logical, and `&` keeps the low half, so every intermediate value is
-- recovered exactly. Nothing here may be rewritten with `//` or a
-- comparison against zero on those intermediates, which would read them
-- as signed.
--
-- Montgomery multiplication (CIOS) replaces division by the modulus
-- with a shift. `enter` and `leave` move a number in and out of the
-- form; `mulm` is the only operation that requires it.

local M = {}

local spack, sunpack = string.pack, string.unpack
local srep, ssub, sbyte = string.rep, string.sub, string.byte

local MASK = 0xffffffff

local Mod = {}
Mod.__index = Mod

-- The inverse of an odd limb modulo 2^32, by Newton iteration: each
-- step doubles the number of correct bits.
local function inv_limb(a)
  local x = 1
  for _ = 1, 6 do x = (x * (2 - a * x)) & MASK end
  return x
end

-- modulus(bytes) -> a context, or nil for a modulus that is even or
-- empty. Montgomery arithmetic needs an odd modulus; every modulus this
-- is used with is prime or an RSA modulus, so both are odd.
function M.modulus(bytes)
  bytes = bytes:gsub("^\0+", "")
  if #bytes == 0 or sbyte(bytes, #bytes) % 2 == 0 then return nil end

  local k = (#bytes + 3) // 4
  local len = k * 4
  local m = srep("\0", len - #bytes) .. bytes

  local limbs = {}
  for i = 1, k do
    -- Limb 1 is the least significant, so the string is read backwards.
    limbs[i] = sunpack(">I4", m, len - i * 4 + 1)
  end

  local self = setmetatable({
    m = m,
    k = k,
    len = len,
    limbs = limbs,
    n0 = (-inv_limb(limbs[1])) & MASK,
    bytes = #bytes,
    zero = srep("\0", len),
    one = srep("\0", len - 1) .. "\1",
    -- Scratch for the Lua multiply, so a multiply allocates its result
    -- and nothing else.
    sa = {}, sb = {}, st = {}, so = {}, sr = {},
    fmt = srep(">I4", k),
  }, Mod)

  -- R^2 mod m, which turns `enter` into one Montgomery multiplication.
  -- Doubling 2 * 32 * k times from 1 reaches it without a division.
  local r2 = self.one
  for _ = 1, 2 * 32 * k do r2 = self:add(r2, r2) end
  self.r2 = r2

  return self
end

-- from(s) -> the value of a big-endian byte string, padded to the
-- modulus's length, or nil when it does not fit. It is not reduced: a
-- caller that may be over the modulus reduces with `reduce`.
function Mod:from(s)
  s = s:gsub("^\0+", "")
  if #s > self.len then return nil, "too many bytes for the modulus" end
  return srep("\0", self.len - #s) .. s
end

-- to_bytes(a, n) -> n big-endian bytes, or the modulus's own length.
function Mod:to_bytes(a, n)
  n = n or self.bytes
  if n <= self.len then return ssub(a, self.len - n + 1) end
  return srep("\0", n - self.len) .. a
end

function Mod:is_zero(a)
  return a == self.zero
end

-- cmp(a, b) -> -1, 0 or 1. Both are the same length and big-endian, so
-- Lua's own string order is the numeric one.
function Mod:cmp(a, b)
  if a == b then return 0 end
  return a < b and -1 or 1
end

function Mod:eq(a, b)
  return a == b
end

-- sub_raw(a, b) -> a - b, and the borrow out. The borrow is what tells
-- a caller whether the subtraction was the one it wanted.
function Mod:sub_raw(a, b)
  local out, borrow, k, len = self.so, 0, self.k, self.len
  -- Limb 1 is the least significant, so the carry runs i = 1 upwards,
  -- and the output is packed most significant first.
  for i = 1, k do
    local off = len - i * 4 + 1
    local d = sunpack(">I4", a, off) - sunpack(">I4", b, off) - borrow
    -- d is at most 32 bits and at least -2^32, so the sign is the
    -- borrow and the low 32 bits are the difference either way.
    out[k - i + 1] = d & MASK
    borrow = d < 0 and 1 or 0
  end
  return spack(self.fmt, table.unpack(out, 1, k)), borrow
end

function Mod:add_raw(a, b)
  local out, carry, k, len = self.so, 0, self.k, self.len
  for i = 1, k do
    local off = len - i * 4 + 1
    local s = sunpack(">I4", a, off) + sunpack(">I4", b, off) + carry
    out[k - i + 1] = s & MASK
    carry = s >> 32
  end
  return spack(self.fmt, table.unpack(out, 1, k)), carry
end

-- Both operands must already be less than the modulus.
function Mod:add(a, b)
  local out, carry = self:add_raw(a, b)
  -- One conditional subtraction is enough: a + b < 2m. A carry out
  -- counts as being over, which the comparison cannot see.
  local sub, borrow = self:sub_raw(out, self.m)
  if carry == 1 or borrow == 0 then return sub end
  return out
end

function Mod:sub(a, b)
  local out, borrow = self:sub_raw(a, b)
  if borrow == 0 then return out end
  return (self:add_raw(out, self.m))
end

function Mod:neg(a)
  if a == self.zero then return a end
  return (self:sub_raw(self.m, a))
end

-- reduce(a) -> a mod m, for an a that is at most a few multiples over.
function Mod:reduce(a)
  while a >= self.m do a = (self:sub_raw(a, self.m)) end
  return a
end

-- mulm(a, b) -> a * b * R^-1 mod m, the Montgomery product (CIOS).
--
-- The scratch tables are the context's, so the only allocation is the
-- result. That matters more than the arithmetic does: the first version
-- of this allocated four tables per multiply and spent most of a
-- verification in the collector.
function Mod:mulm(a, b)
  local k, m, n0 = self.k, self.limbs, self.n0
  local A, B, t = self.sa, self.sb, self.st
  local len = self.len

  for i = 1, k do
    local off = len - i * 4 + 1
    A[i] = sunpack(">I4", a, off)
    B[i] = sunpack(">I4", b, off)
    t[i] = 0
  end
  t[k + 1], t[k + 2] = 0, 0

  for i = 1, k do
    local bi, c = B[i], 0
    for j = 1, k do
      local p = t[j] + A[j] * bi + c
      t[j] = p & MASK
      c = p >> 32
    end
    local p = t[k + 1] + c
    t[k + 1] = p & MASK
    t[k + 2] = t[k + 2] + (p >> 32)

    local u = (t[1] * n0) & MASK
    c = (t[1] + u * m[1]) >> 32
    for j = 2, k do
      p = t[j] + u * m[j] + c
      t[j - 1] = p & MASK
      c = p >> 32
    end
    p = t[k + 1] + c
    t[k] = p & MASK
    t[k + 1] = t[k + 2] + (p >> 32)
    t[k + 2] = 0
  end

  -- Most significant limb first, which is the byte order out.
  local out = self.sr
  for i = 1, k do out[i] = t[k - i + 1] end
  local s = spack(self.fmt, table.unpack(out, 1, k))

  if t[k + 1] ~= 0 then return (self:sub_raw(s, self.m)) end
  local sub, borrow = self:sub_raw(s, self.m)
  if borrow == 0 then return sub end
  return s
end

-- The C backend, when it is there. It computes the same function on the
-- same byte strings, so the two are interchangeable and the Lua one
-- above stays the reference the suite runs against.
Mod.mulm_lua, Mod.add_lua, Mod.sub_lua = Mod.mulm, Mod.add, Mod.sub

local ok, native = pcall(require, "crypto.native")
if ok and type(native) == "table" and native.bignum_mulm then
  local mulm = native.bignum_mulm
  local addm, subm = native.bignum_addm, native.bignum_subm
  M.native = { mulm = mulm, addm = addm, subm = subm }

  function Mod:mulm(a, b)
    return mulm(a, b, self.m, self.n0)
  end

  function Mod:add(a, b)
    return addm(a, b, self.m)
  end

  function Mod:sub(a, b)
    return subm(a, b, self.m)
  end
end

-- Into and out of Montgomery form.
function Mod:enter(a)
  return self:mulm(a, self.r2)
end

function Mod:leave(a)
  return self:mulm(a, self.one)
end

-- exp(a, e) -> a^e mod m, with e a big-endian byte string. Square and
-- multiply, most significant bit first. The exponent is public in every
-- caller here.
function Mod:exp(a, e)
  local acc, base = nil, self:enter(a)

  for i = 1, #e do
    local byte = sbyte(e, i)
    for bit = 7, 0, -1 do
      if acc then acc = self:mulm(acc, acc) end
      if (byte >> bit) & 1 == 1 then
        acc = acc and self:mulm(acc, base) or base
      end
    end
  end

  if not acc then return self.one end
  return self:leave(acc)
end

-- inv(a) -> a^-1 mod m by Fermat's little theorem, which needs a prime
-- modulus. Every modulus this is called on is one.
function Mod:inv(a)
  local two = srep("\0", self.len - 1) .. "\2"
  return self:exp(a, (self:sub_raw(self.m, two)))
end

return M
