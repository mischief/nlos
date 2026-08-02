-- Poly1305, RFC 8439. Ported from poly1305-donna-32, which is public
-- domain (Andrew Moon).
--
-- Why donna's 5x26-bit limbs rather than TweetNaCl's 17x8-bit ones: the
-- 8-bit form needs 289 multiplies per 16-byte block against donna's 25,
-- and this runs over every byte on the wire. The 26-bit choice is exactly
-- what makes it fit Lua: a limb product is under 2^52 and an accumulated
-- column under 2^57, so nothing leaves the 63-bit range Lua integers give
-- without any of the 128-bit trickery donna-64 needs.

local M = {}

local sunpack, spack = string.unpack, string.pack

local Poly = {}
Poly.__index = Poly

function M.new(key)
  assert(#key == 32, "poly1305 key must be 32 bytes")

  local t0 = sunpack("<I4", key, 1)
  local t1 = sunpack("<I4", key, 5)
  local t2 = sunpack("<I4", key, 9)
  local t3 = sunpack("<I4", key, 13)

  local s = setmetatable({}, Poly)

  -- r is clamped as it is unpacked
  s.r0 = t0 & 0x3ffffff
  s.r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03
  s.r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff
  s.r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff
  s.r4 = (t3 >> 8) & 0x00fffff

  s.s1, s.s2, s.s3, s.s4 = s.r1 * 5, s.r2 * 5, s.r3 * 5, s.r4 * 5

  s.h0, s.h1, s.h2, s.h3, s.h4 = 0, 0, 0, 0, 0

  s.pad0 = sunpack("<I4", key, 17)
  s.pad1 = sunpack("<I4", key, 21)
  s.pad2 = sunpack("<I4", key, 25)
  s.pad3 = sunpack("<I4", key, 29)

  s.buf, s.buflen = {}, 0

  return s
end

-- One 16-byte block. `hibit` is 1<<24 for a full block and 0 for the
-- final short one, which carries its own 0x01 terminator instead.
function Poly:block(m, off, hibit)
  local t0 = sunpack("<I4", m, off)
  local t1 = sunpack("<I4", m, off + 4)
  local t2 = sunpack("<I4", m, off + 8)
  local t3 = sunpack("<I4", m, off + 12)

  local h0 = self.h0 + (t0 & 0x3ffffff)
  local h1 = self.h1 + (((t0 >> 26) | (t1 << 6)) & 0x3ffffff)
  local h2 = self.h2 + (((t1 >> 20) | (t2 << 12)) & 0x3ffffff)
  local h3 = self.h3 + (((t2 >> 14) | (t3 << 18)) & 0x3ffffff)
  local h4 = self.h4 + ((t3 >> 8) | hibit)

  local r0, r1, r2, r3, r4 = self.r0, self.r1, self.r2, self.r3, self.r4
  local s1, s2, s3, s4 = self.s1, self.s2, self.s3, self.s4

  local d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
  local d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
  local d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
  local d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
  local d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0

  local c = d0 >> 26; h0 = d0 & 0x3ffffff
  d1 = d1 + c; c = d1 >> 26; h1 = d1 & 0x3ffffff
  d2 = d2 + c; c = d2 >> 26; h2 = d2 & 0x3ffffff
  d3 = d3 + c; c = d3 >> 26; h3 = d3 & 0x3ffffff
  d4 = d4 + c; c = d4 >> 26; h4 = d4 & 0x3ffffff
  h0 = h0 + c * 5; c = h0 >> 26; h0 = h0 & 0x3ffffff
  h1 = h1 + c

  self.h0, self.h1, self.h2, self.h3, self.h4 = h0, h1, h2, h3, h4
end

function Poly:update(m)
  -- Anything left from the last call is completed first.
  if self.buflen > 0 then
    local want = 16 - self.buflen
    local take = #m < want and #m or want
    self.buf[#self.buf + 1] = m:sub(1, take)
    self.buflen = self.buflen + take
    m = m:sub(take + 1)
    if self.buflen == 16 then
      self:block(table.concat(self.buf), 1, 1 << 24)
      self.buf, self.buflen = {}, 0
    end
  end

  local n = #m
  local full = n - (n % 16)
  for off = 1, full, 16 do self:block(m, off, 1 << 24) end

  if full < n then
    self.buf = { m:sub(full + 1) }
    self.buflen = n - full
  end

  return self
end

function Poly:final()
  if self.buflen > 0 then
    local last = table.concat(self.buf) .. "\1"
    self:block(last .. ("\0"):rep(16 - #last), 1, 0)
  end

  local h0, h1, h2, h3, h4 = self.h0, self.h1, self.h2, self.h3, self.h4

  local c = h1 >> 26; h1 = h1 & 0x3ffffff
  h2 = h2 + c; c = h2 >> 26; h2 = h2 & 0x3ffffff
  h3 = h3 + c; c = h3 >> 26; h3 = h3 & 0x3ffffff
  h4 = h4 + c; c = h4 >> 26; h4 = h4 & 0x3ffffff
  h0 = h0 + c * 5; c = h0 >> 26; h0 = h0 & 0x3ffffff
  h1 = h1 + c

  -- h + -p, kept branch-free: g is used only if the subtraction did not
  -- borrow, and which one that is must not be a branch on secret state.
  local g0 = h0 + 5; c = g0 >> 26; g0 = g0 & 0x3ffffff
  local g1 = h1 + c; c = g1 >> 26; g1 = g1 & 0x3ffffff
  local g2 = h2 + c; c = g2 >> 26; g2 = g2 & 0x3ffffff
  local g3 = h3 + c; c = g3 >> 26; g3 = g3 & 0x3ffffff
  local g4 = h4 + c - (1 << 26)

  local mask = (g4 >> 63) - 1          -- 0 on borrow, all-ones otherwise
  local nmask = ~mask
  h0 = (h0 & nmask) | (g0 & mask)
  h1 = (h1 & nmask) | (g1 & mask)
  h2 = (h2 & nmask) | (g2 & mask)
  h3 = (h3 & nmask) | (g3 & mask)
  h4 = (h4 & nmask) | (g4 & mask)

  h0 = (h0 | (h1 << 26)) & 0xffffffff
  h1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff
  h2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff
  h3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff

  local f = h0 + self.pad0; h0 = f & 0xffffffff
  f = h1 + self.pad1 + (f >> 32); h1 = f & 0xffffffff
  f = h2 + self.pad2 + (f >> 32); h2 = f & 0xffffffff
  f = h3 + self.pad3 + (f >> 32); h3 = f & 0xffffffff

  return spack("<I4I4I4I4", h0, h1, h2, h3)
end

-- One-shot.
function M.auth(key, msg)
  return M.new(key):update(msg):final()
end

M.TAG_LEN = 16

--------------------------------------------------------------------------

-- As in chacha20: the C implementation takes over when it is there, and
-- the Lua one remains as M.pure for the platforms and the tests that
-- want it. Only the one-shot is replaced -- the streaming interface has
-- no caller on the hot path, and one implementation of the block
-- accumulator is enough to keep straight.
M.pure = { new = M.new, auth = M.auth }

local ok, native = pcall(require, "ssh.crypto.native")
if ok and type(native) == "table" and native.poly1305_auth then
  M.native = { auth = native.poly1305_auth }
  M.auth = M.native.auth
end

return M
