-- The TLS 1.3 record layer, RFC 8446 5. QUIC does without it; TCP needs
-- it.
--
-- A record is a five-byte header and a body. The header gives the
-- content type, a legacy version and the body length. Once keys exist,
-- the body is an AEAD sealing of the plaintext and one trailing byte.
-- That byte holds the true content type. The header then always says
-- application_data, whatever the record contains.
--
-- Three properties matter:
--
--   - The nonce is the static IV exclusive-ored with the sequence
--     number. The sequence number counts records and does not reset
--     while a key lives. A repeated nonce loses authentication, not
--     only secrecy.
--   - Each direction has its own key, IV and sequence number. A mixed
--     pair fails to open.
--   - The header is the additional data. A record therefore cannot be
--     truncated or re-typed without a tag failure. `open` returns nil
--     for every failure, a short body included.

local aead = require "crypto.aead"
local hkdf = require "crypto.hkdf"
local sha256 = require "crypto.sha256"

local M = {}

local spack, sunpack = string.pack, string.unpack
local schar, sbyte, sconcat = string.char, string.byte, table.concat

M.CHANGE_CIPHER_SPEC = 20
M.ALERT = 21
M.HANDSHAKE = 22
M.APPLICATION_DATA = 23

M.HEADER_LEN = 5

-- RFC 8446 5.1 and 5.2: a record carries at most 2^14 bytes of
-- plaintext, and a protected record body is at most 2^14 + 256 bytes.
-- The larger figure holds the content type, the tag and any padding.
-- The limit keeps a length field off the network from sizing a buffer.
M.MAX_PLAINTEXT = 16384
M.MAX_CIPHERTEXT = M.MAX_PLAINTEXT + 256

-- RFC 8446 5.5: for ChaCha20-Poly1305 the sequence number wraps before
-- the cryptographic limit is reached, so the wrap is the limit. A
-- repeated sequence number repeats a nonce, which loses authentication
-- under the key it repeats. Lua's integers are signed, so the refusal
-- is at 2^63 - 1, before the count can go negative.
M.MAX_SEQ = math.maxinteger

local K = {}
K.__index = K

-- new(secret) -> the key, IV and sequence number for one direction,
-- derived from one traffic secret. RFC 8446 7.3.
function M.new(secret)
  return setmetatable({
    secret = secret,
    key = hkdf.expand_label(sha256, secret, "key", "", aead.KEY_LEN),
    iv = hkdf.expand_label(sha256, secret, "iv", "", aead.NONCE_LEN),
    seq = 0,
  }, K)
end

-- The per-record nonce: the sequence number, big-endian in the low
-- eight bytes of a NONCE_LEN field, exclusive-ored with the IV.
function K:nonce()
  local n = spack(">I4I8", 0, self.seq)
  local out = {}
  for i = 1, aead.NONCE_LEN do
    out[i] = schar(sbyte(self.iv, i) ~ sbyte(n, i))
  end
  return sconcat(out)
end

function M.header(ctype, len)
  return spack(">I1I2I2", ctype, 0x0303, len)
end

-- An unprotected record. Only the ClientHello and the dummy
-- ChangeCipherSpec need one.
function M.plain(ctype, body)
  return M.header(ctype, #body) .. body
end

-- parse_header(s) -> content type, body length.
function M.parse_header(s)
  local ctype, _, len = sunpack(">I1I2I2", s)
  return ctype, len
end

-- exhausted() -> true when this key has sealed or opened every record
-- it may. The caller updates the key, or stops.
function K:exhausted()
  return self.seq >= M.MAX_SEQ
end

-- seal(ctype, plaintext) -> one complete record, or nil when the key is
-- exhausted.
function K:seal(ctype, plaintext)
  if self:exhausted() then return nil end
  local inner = plaintext .. schar(ctype)
  local head = M.header(M.APPLICATION_DATA, #inner + aead.TAG_LEN)
  local rec = head .. aead.seal(self.key, self:nonce(), inner, head)
  self.seq = self.seq + 1
  return rec
end

-- open(head, body) -> plaintext, content type. nil for any failure.
--
-- Trailing zeros are padding. They are removed to find the content
-- type. An all-zero plaintext has no content type and is an error.
function K:open(head, body)
  if self:exhausted() then return nil end
  local inner = aead.open(self.key, self:nonce(), body, head)
  if not inner then return nil end
  self.seq = self.seq + 1
  if #inner > M.MAX_PLAINTEXT + 1 then return nil end

  local i = #inner
  while i > 0 and sbyte(inner, i) == 0 do i = i - 1 end
  if i == 0 then return nil end
  return inner:sub(1, i - 1), sbyte(inner, i)
end

-- The next generation of a traffic secret, RFC 8446 7.2. The caller
-- replaces the old key with the result; the two do not overlap.
function K:update()
  return M.new(hkdf.expand_label(sha256, self.secret, "traffic upd", "", 32))
end

return M
