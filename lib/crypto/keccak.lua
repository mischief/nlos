-- Keccak-f[1600], and the four sponges ML-KEM needs: SHA3-256, SHA3-512,
-- SHAKE128 and SHAKE256 (FIPS 202).
--
-- Lua 5.4 is a good fit for this and a bad fit for very little of it: a
-- lane is exactly a 64-bit integer, `~` is xor, and `>>` is logical, so
-- the rotate is a rotate and nothing needs masking. This is the one
-- primitive here that wants no tricks at all.
--
-- ---- the constants are computed, not copied ----
--
-- The 24 round constants and the 25 rotation offsets are generated at
-- load time from the definitions in FIPS 202 rather than written out as
-- tables of magic numbers. That is not cleverness for its own sake: a
-- mistyped rotation offset produces a hash that is wrong in no visible
-- way, and there is nothing in the value itself to check against. The
-- generators are short enough to read and the round constants are the
-- LFSR the standard describes, so the code says why each number is what
-- it is. spec/hash_spec.lua then checks the whole thing against
-- openssl.

local M = {}

local spack, sunpack, schar = string.pack, string.unpack, string.char
local concat = table.concat

--------------------------------------------------------------------------
-- constants

-- rc(t): the LFSR of FIPS 202 section 3.2.5, one bit per call.
local function lfsr()
  local r = 0x01
  return function()
    local bit = r & 1
    r = r << 1
    if r & 0x100 ~= 0 then
      r = (r ~ 0x71) & 0xff        -- x^8 + x^6 + x^5 + x^4 + 1
    end
    return bit
  end
end

-- RC[i] has bit 2^j - 1 set from rc(j + 7i), for j = 0..6.
local RC = {}
do
  local rc = lfsr()
  for i = 1, 24 do
    local c = 0
    for j = 0, 6 do
      local bit = rc()
      if bit == 1 then
        c = c | (1 << ((1 << j) - 1))
      end
    end
    RC[i] = c
  end
end

-- The rotation offsets, from the (x,y) walk of FIPS 202 section 3.2.2:
-- start at (1,0) and step (x,y) <- (y, 2x+3y), with offset
-- (t+1)(t+2)/2 mod 64 at step t. Lane (0,0) is never rotated.
--
-- ROT and PI are stored flat, indexed 1..25 as x + 5y + 1, because the
-- permutation below runs 24 times per block and a nested table lookup
-- per lane is the difference between fast and not.
local ROT, PI = {}, {}
do
  for i = 1, 25 do ROT[i] = 0 end

  local x, y = 1, 0
  for t = 0, 23 do
    local idx = x + 5 * y + 1

    ROT[idx] = ((t + 1) * (t + 2) // 2) % 64
    x, y = y, (2 * x + 3 * y) % 5
  end

  -- pi: lane (x,y) moves to (y, 2x+3y)
  for yy = 0, 4 do
    for xx = 0, 4 do
      PI[xx + 5 * yy + 1] = yy + 5 * ((2 * xx + 3 * yy) % 5) + 1
    end
  end
end

--------------------------------------------------------------------------
-- the permutation

local function rotl(v, n)
  if n == 0 then return v end
  return (v << n) | (v >> (64 - n))
end

local B = {}

local function keccakf(s)
  for round = 1, 24 do
    -- theta
    local c1 = s[1] ~ s[6] ~ s[11] ~ s[16] ~ s[21]
    local c2 = s[2] ~ s[7] ~ s[12] ~ s[17] ~ s[22]
    local c3 = s[3] ~ s[8] ~ s[13] ~ s[18] ~ s[23]
    local c4 = s[4] ~ s[9] ~ s[14] ~ s[19] ~ s[24]
    local c5 = s[5] ~ s[10] ~ s[15] ~ s[20] ~ s[25]

    local d1 = c5 ~ rotl(c2, 1)
    local d2 = c1 ~ rotl(c3, 1)
    local d3 = c2 ~ rotl(c4, 1)
    local d4 = c3 ~ rotl(c5, 1)
    local d5 = c4 ~ rotl(c1, 1)

    for i = 1, 25, 5 do
      s[i] = s[i] ~ d1
      s[i + 1] = s[i + 1] ~ d2
      s[i + 2] = s[i + 2] ~ d3
      s[i + 3] = s[i + 3] ~ d4
      s[i + 4] = s[i + 4] ~ d5
    end

    -- rho and pi together: rotate on the way to the new position
    for i = 1, 25 do
      B[PI[i]] = rotl(s[i], ROT[i])
    end

    -- chi, a row at a time
    for i = 1, 25, 5 do
      local b1, b2, b3, b4, b5 =
        B[i], B[i + 1], B[i + 2], B[i + 3], B[i + 4]

      s[i] = b1 ~ (~b2 & b3)
      s[i + 1] = b2 ~ (~b3 & b4)
      s[i + 2] = b3 ~ (~b4 & b5)
      s[i + 3] = b4 ~ (~b5 & b1)
      s[i + 4] = b5 ~ (~b1 & b2)
    end

    -- iota
    s[1] = s[1] ~ RC[round]
  end
end

--------------------------------------------------------------------------
-- the sponge

local function newstate()
  local s = {}
  for i = 1, 25 do s[i] = 0 end
  return s
end

-- Absorb `msg` at the given rate (in bytes) and apply the domain
-- padding, leaving the state ready to squeeze.
local function absorb(rate, pad, msg)
  local s = newstate()
  local lanes = rate // 8
  local n = #msg
  local off = 0

  while n - off >= rate do
    for i = 1, lanes do
      s[i] = s[i] ~ sunpack("<i8", msg, off + (i - 1) * 8 + 1)
    end
    keccakf(s)
    off = off + rate
  end

  -- the final block: what is left, the domain separator, zeroes, and
  -- the high bit of the last byte.
  local tail = msg:sub(off + 1) .. schar(pad)

  tail = tail .. ("\0"):rep(rate - #tail)
  tail = tail:sub(1, rate - 1) .. schar(tail:byte(rate) | 0x80)

  for i = 1, lanes do
    s[i] = s[i] ~ sunpack("<i8", tail, (i - 1) * 8 + 1)
  end
  keccakf(s)

  return s
end

local function squeeze(s, rate, outlen)
  local lanes = rate // 8
  local out, n = {}, 0
  local got = 0

  while got < outlen do
    for i = 1, lanes do
      n = n + 1
      out[n] = spack("<i8", s[i])
    end
    got = got + rate
    if got < outlen then keccakf(s) end
  end

  return concat(out):sub(1, outlen)
end

--------------------------------------------------------------------------
-- what callers use

function M.sha3_256(msg) return squeeze(absorb(136, 0x06, msg), 136, 32) end
function M.sha3_512(msg) return squeeze(absorb(72, 0x06, msg), 72, 64) end
function M.shake128(msg, outlen) return squeeze(absorb(168, 0x1f, msg), 168, outlen) end
function M.shake256(msg, outlen) return squeeze(absorb(136, 0x1f, msg), 136, outlen) end

-- An incremental SHAKE reader.
--
-- ML-KEM's SampleNTT rejects candidate coefficients, so it cannot know
-- in advance how much output it needs -- it asks for more until it has
-- 256 accepted values. Squeezing a guessed amount and hoping is how that
-- goes subtly wrong.
function M.shake128_reader(seed)
  local s = absorb(168, 0x1f, seed)
  local buf, pos = "", 1

  return function(n)
    while #buf - pos + 1 < n do
      buf = buf:sub(pos) .. squeeze(s, 168, 168)
      pos = 1
      keccakf(s)
    end
    local out = buf:sub(pos, pos + n - 1)

    pos = pos + n
    return out
  end
end

M.RC = RC
M.ROT = ROT

return M
