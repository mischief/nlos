-- ChaCha20, RFC 8439. A transliteration of DJB's reference code, which is
-- public domain.
--
-- Two entry points, because SSH needs both: `block` exposes the raw block
-- function (chacha20-poly1305@openssh.com derives the Poly1305 key from
-- block 0), and `xor` is the stream cipher proper.
--
-- If ssh.crypto.native is present its C implementation is used instead.
-- The Lua one is never discarded: it stays reachable as `M.pure`, which
-- is what runs where no C is available and what the spec suite runs its
-- known-answer tests against a second time, making the two a differential
-- test of each other for free.

local M = {}

local MASK = 0xffffffff
local spack, sunpack, schar = string.pack, string.unpack, string.char
local concat = table.concat

local function rotl(x, n)
  return ((x << n) | (x >> (32 - n))) & MASK
end

-- The state is kept in 16 locals rather than a table: this is the hot loop
-- of the whole cipher and table indexing costs more than the register
-- pressure saves.
local function core(out, k, counter, nonce)
  local x0, x1, x2, x3 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
  local x4, x5, x6, x7 = k[1], k[2], k[3], k[4]
  local x8, x9, x10, x11 = k[5], k[6], k[7], k[8]
  local x12, x13, x14, x15 = counter, nonce[1], nonce[2], nonce[3]

  local a, b, c, d, e, f, g, h = x0, x1, x2, x3, x4, x5, x6, x7
  local i, j, kk, l, m, n, o, p = x8, x9, x10, x11, x12, x13, x14, x15

  for _ = 1, 10 do
    -- column rounds
    a = (a + e) & MASK; m = rotl(m ~ a, 16)
    i = (i + m) & MASK; e = rotl(e ~ i, 12)
    a = (a + e) & MASK; m = rotl(m ~ a, 8)
    i = (i + m) & MASK; e = rotl(e ~ i, 7)

    b = (b + f) & MASK; n = rotl(n ~ b, 16)
    j = (j + n) & MASK; f = rotl(f ~ j, 12)
    b = (b + f) & MASK; n = rotl(n ~ b, 8)
    j = (j + n) & MASK; f = rotl(f ~ j, 7)

    c = (c + g) & MASK; o = rotl(o ~ c, 16)
    kk = (kk + o) & MASK; g = rotl(g ~ kk, 12)
    c = (c + g) & MASK; o = rotl(o ~ c, 8)
    kk = (kk + o) & MASK; g = rotl(g ~ kk, 7)

    d = (d + h) & MASK; p = rotl(p ~ d, 16)
    l = (l + p) & MASK; h = rotl(h ~ l, 12)
    d = (d + h) & MASK; p = rotl(p ~ d, 8)
    l = (l + p) & MASK; h = rotl(h ~ l, 7)

    -- diagonal rounds
    a = (a + f) & MASK; p = rotl(p ~ a, 16)
    kk = (kk + p) & MASK; f = rotl(f ~ kk, 12)
    a = (a + f) & MASK; p = rotl(p ~ a, 8)
    kk = (kk + p) & MASK; f = rotl(f ~ kk, 7)

    b = (b + g) & MASK; m = rotl(m ~ b, 16)
    l = (l + m) & MASK; g = rotl(g ~ l, 12)
    b = (b + g) & MASK; m = rotl(m ~ b, 8)
    l = (l + m) & MASK; g = rotl(g ~ l, 7)

    c = (c + h) & MASK; n = rotl(n ~ c, 16)
    i = (i + n) & MASK; h = rotl(h ~ i, 12)
    c = (c + h) & MASK; n = rotl(n ~ c, 8)
    i = (i + n) & MASK; h = rotl(h ~ i, 7)

    d = (d + e) & MASK; o = rotl(o ~ d, 16)
    j = (j + o) & MASK; e = rotl(e ~ j, 12)
    d = (d + e) & MASK; o = rotl(o ~ d, 8)
    j = (j + o) & MASK; e = rotl(e ~ j, 7)
  end

  out[1] = (a + x0) & MASK;  out[2] = (b + x1) & MASK
  out[3] = (c + x2) & MASK;  out[4] = (d + x3) & MASK
  out[5] = (e + x4) & MASK;  out[6] = (f + x5) & MASK
  out[7] = (g + x6) & MASK;  out[8] = (h + x7) & MASK
  out[9] = (i + x8) & MASK;  out[10] = (j + x9) & MASK
  out[11] = (kk + x10) & MASK; out[12] = (l + x11) & MASK
  out[13] = (m + x12) & MASK; out[14] = (n + x13) & MASK
  out[15] = (o + x14) & MASK; out[16] = (p + x15) & MASK
end

local function loadkey(key)
  assert(#key == 32, "chacha20 key must be 32 bytes")
  local k = {}
  for i = 1, 8 do k[i] = sunpack("<I4", key, (i - 1) * 4 + 1) end
  return k
end

local function loadnonce(nonce)
  assert(#nonce == 12, "chacha20 nonce must be 12 bytes")
  local n = {}
  for i = 1, 3 do n[i] = sunpack("<I4", nonce, (i - 1) * 4 + 1) end
  return n
end

-- One 64-byte keystream block, as a string.
function M.block(key, counter, nonce)
  local out = {}
  core(out, loadkey(key), counter & MASK, loadnonce(nonce))
  return spack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", table.unpack(out, 1, 16))
end

-- Stream cipher. Encryption and decryption are the same operation.
function M.xor(key, counter, nonce, data)
  local k, n = loadkey(key), loadnonce(nonce)
  local out, oi = {}, 0
  local ks = {}
  local len = #data

  for off = 0, len - 1, 64 do
    core(ks, k, (counter + off // 64) & MASK, n)
    local chunk = len - off
    if chunk > 64 then chunk = 64 end
    for i = 0, chunk - 1 do
      local word = ks[(i >> 2) + 1]
      local b = (word >> ((i & 3) * 8)) & 0xff
      oi = oi + 1
      out[oi] = schar(data:byte(off + i + 1) ~ b)
    end
  end

  return concat(out)
end

--------------------------------------------------------------------------

M.pure = { block = M.block, xor = M.xor }

local ok, native = pcall(require, "ssh.crypto.native")
if ok and type(native) == "table" and native.chacha20_xor then
  M.native = { block = native.chacha20_block, xor = native.chacha20_xor }
  M.block, M.xor = M.native.block, M.native.xor
end

return M
