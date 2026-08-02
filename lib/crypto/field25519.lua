-- Arithmetic in GF(2^255-19), transliterated from TweetNaCl, which is
-- public domain (Bernstein, van Gastel, Janssen, Lange, Schwabe, Smetsers).
--
-- A field element is a 0-based table of 16 signed limbs, radix 2^16, the
-- `gf` type of the original. Both X25519 and Ed25519 sit on top of this.
--
-- Two things had to change on the way across, and both are load-bearing:
--
--   * C's `>>` on a signed type is an arithmetic shift, and TweetNaCl
--     relies on that for carries of negative limbs. Lua's `>>` is
--     logical. Every such shift is written as `// 2^n` here, which is
--     floor division and therefore exactly the arithmetic shift. Shifts
--     that merely extract a low bit are left as `>>`, where the two
--     agree.
--   * A limb can legitimately be negative between reductions, so nothing
--     may assume an unsigned range until pack.
--
-- Reduction is lazy in the same places TweetNaCl leaves it lazy: limbs
-- stay under about 2^22 through a multiply, which keeps the 256-limb
-- product columns of M() inside Lua's 63-bit integers with room to spare.

local M = {}

local function gf(init)
  local r = {}
  for i = 0, 15 do r[i] = 0 end
  if init then
    for i = 1, #init do r[i - 1] = init[i] end
  end
  return r
end
M.gf = gf

M.gf0 = gf()
M.gf1 = gf { 1 }
M._121665 = gf { 0xDB41, 1 }

M.D = gf { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
           0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 }
M.D2 = gf { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
            0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 }
M.X = gf { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
           0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 }
M.Y = gf { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
           0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 }
M.I = gf { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
           0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 }

function M.set(r, a)
  for i = 0, 15 do r[i] = a[i] end
end

function M.A(o, a, b)
  for i = 0, 15 do o[i] = a[i] + b[i] end
end

function M.Z(o, a, b)
  for i = 0, 15 do o[i] = a[i] - b[i] end
end

function M.car25519(o)
  for i = 0, 15 do
    o[i] = o[i] + 65536
    local c = o[i] // 65536
    if i < 15 then
      o[i + 1] = o[i + 1] + c - 1
    else
      o[0] = o[0] + 38 * (c - 1)
    end
    o[i] = o[i] - c * 65536
  end
end
local car25519 = M.car25519

local t = {}
for i = 0, 30 do t[i] = 0 end

function M.M(o, a, b)
  for i = 0, 30 do t[i] = 0 end
  -- No short-circuit on a zero limb, however tempting: the limbs here are
  -- secret and the skip would be a timing signal.
  for i = 0, 15 do
    local ai = a[i]
    for j = 0, 15 do t[i + j] = t[i + j] + ai * b[j] end
  end
  for i = 0, 14 do t[i] = t[i] + 38 * t[i + 16] end
  for i = 0, 15 do o[i] = t[i] end
  car25519(o)
  car25519(o)
end
local Mul = M.M

function M.S(o, a)
  Mul(o, a, a)
end
local S = M.S

-- Conditional swap, constant time: b is 0 or 1.
function M.sel25519(p, q, b)
  local c = ~(b - 1)
  for i = 0, 15 do
    local x = c & (p[i] ~ q[i])
    p[i] = p[i] ~ x
    q[i] = q[i] ~ x
  end
end
local sel25519 = M.sel25519

-- Fully reduce and serialise, little-endian, 32 bytes into a 0-based table.
function M.pack25519(o, n)
  local m, tt = gf(), gf()
  M.set(tt, n)
  car25519(tt); car25519(tt); car25519(tt)
  for _ = 1, 2 do
    m[0] = tt[0] - 0xffed
    for i = 1, 14 do
      m[i] = tt[i] - 0xffff - ((m[i - 1] >> 16) & 1)
      m[i - 1] = m[i - 1] & 0xffff
    end
    m[15] = tt[15] - 0x7fff - ((m[14] >> 16) & 1)
    local b = (m[15] >> 16) & 1
    m[14] = m[14] & 0xffff
    sel25519(tt, m, 1 - b)
  end
  for i = 0, 15 do
    o[2 * i] = tt[i] & 0xff
    o[2 * i + 1] = (tt[i] >> 8) & 0xff
  end
end

function M.unpack25519(o, n)
  for i = 0, 15 do o[i] = n[2 * i] + (n[2 * i + 1] << 8) end
  o[15] = o[15] & 0x7fff
end

function M.neq25519(a, b)
  local c, d = {}, {}
  M.pack25519(c, a)
  M.pack25519(d, b)
  local diff = 0
  for i = 0, 31 do diff = diff | (c[i] ~ d[i]) end
  return diff ~= 0
end

-- Least significant bit of the fully reduced value: Ed25519's sign bit.
function M.par25519(a)
  local d = {}
  M.pack25519(d, a)
  return d[0] & 1
end

function M.inv25519(o, i)
  local c = gf()
  M.set(c, i)
  for a = 253, 0, -1 do
    S(c, c)
    if a ~= 2 and a ~= 4 then Mul(c, c, i) end
  end
  M.set(o, c)
end

-- x^((p-5)/8), the square-root helper Ed25519 decompression needs.
function M.pow2523(o, i)
  local c = gf()
  M.set(c, i)
  for a = 250, 0, -1 do
    S(c, c)
    if a ~= 1 then Mul(c, c, i) end
  end
  M.set(o, c)
end

return M
