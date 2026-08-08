-- AEAD_CHACHA20_POLY1305, RFC 8439 2.8.
--
-- The primitives were already here for SSH, but not this construction:
-- chacha20-poly1305@openssh.com is OpenSSH's own framing, with two keys
-- and a separately encrypted length field, and it is not the IETF AEAD.
-- TLS 1.3 and QUIC want the IETF one, which is this file.
--
-- The parts that are easy to get wrong and are the whole of the security
-- argument:
--
--   - The one-time Poly1305 key is block 0 of the keystream, and the
--     ciphertext starts at block 1. Reusing block 0 for data would hand
--     the authentication key to anyone who knows a plaintext byte.
--   - AAD and ciphertext are each padded to a 16-byte boundary, and the
--     trailer is their two lengths as little-endian u64. Without the
--     padding and the lengths a message can be re-split between AAD and
--     ciphertext with the same tag.
--   - The tag is compared in constant time, and open() returns nothing
--     but a failure flag: a caller must not see unauthenticated
--     plaintext, even to look at it.

local chacha20 = require "crypto.chacha20"
local poly1305 = require "crypto.poly1305"
local util = require "crypto.util"

local M = {}

local spack, srep = string.pack, string.rep

M.KEY_LEN = 32
M.NONCE_LEN = 12
M.TAG_LEN = 16

local function pad16(s)
  local r = #s % 16
  return r == 0 and "" or srep("\0", 16 - r)
end

local function tag(key, nonce, aad, ct)
  -- Block 0 is the Poly1305 key: 32 bytes of it, and the other 32 are
  -- discarded rather than used for anything.
  local otk = chacha20.block(key, 0, nonce):sub(1, 32)
  return poly1305.auth(otk, aad .. pad16(aad) .. ct .. pad16(ct)
                            .. spack("<I8I8", #aad, #ct))
end

-- seal(key, nonce, plaintext, aad) -> ciphertext .. tag
function M.seal(key, nonce, plaintext, aad)
  aad = aad or ""
  local ct = chacha20.xor(key, 1, nonce, plaintext)
  return ct .. tag(key, nonce, aad, ct)
end

-- open(key, nonce, sealed, aad) -> plaintext, or nil on any failure.
-- Too short counts as a failure, not an error: a truncated packet off the
-- network is an ordinary event and reaches this the same way a forgery
-- does.
function M.open(key, nonce, sealed, aad)
  aad = aad or ""
  if #sealed < M.TAG_LEN then return nil end
  local ct = sealed:sub(1, #sealed - M.TAG_LEN)
  local got = sealed:sub(#sealed - M.TAG_LEN + 1)
  if not util.ct_eq(got, tag(key, nonce, aad, ct)) then return nil end
  return chacha20.xor(key, 1, nonce, ct)
end

return M
