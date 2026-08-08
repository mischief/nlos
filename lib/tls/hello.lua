-- ClientHello and ServerHello, RFC 8446 4.1.
--
-- Only what a server needs to answer with one algorithm in every slot,
-- which is the same stance ssh/kex.lua takes: read the peer's lists,
-- check that what we do is in them, and refuse otherwise. There is no
-- preference order to express when there is one choice.
--
-- The legacy fields are not vestigial in TLS 1.3, they are load-bearing
-- middlebox camouflage: legacy_version says 1.2 and the real version is
-- in an extension, the session ID is echoed back verbatim, and the
-- compression byte must be zero. Getting any of them wrong produces a
-- handshake that a compliant peer rejects for reasons that read like
-- something else entirely.

local wire = require "tls.wire"

local M = {}

M.CLIENT_HELLO = 1
M.SERVER_HELLO = 2
M.ENCRYPTED_EXTENSIONS = 8
M.CERTIFICATE = 11
M.CERTIFICATE_REQUEST = 13
M.CERTIFICATE_VERIFY = 15
M.FINISHED = 20

M.EXT = {
  server_name = 0,
  supported_groups = 10,
  signature_algorithms = 13,
  alpn = 16,
  supported_versions = 43,
  psk_key_exchange_modes = 45,
  key_share = 51,
  quic_transport_parameters = 57,
}

-- The named values this implementation knows. One per slot.
M.TLS13 = 0x0304
M.X25519 = 0x001d
M.ED25519 = 0x0807
M.ECDSA_P256 = 0x0403
M.AES_128_GCM_SHA256 = 0x1301
M.CHACHA20_POLY1305_SHA256 = 0x1303

-- parse_client_hello(body) -> table, or nil, reason
function M.parse_client_hello(s)
  local off = 1
  local version, random, session, suites, comp, exts

  version, off = wire.int(s, off, 2)
  if not version then return nil, "truncated version" end
  random = s:sub(off, off + 31)
  off = off + 32
  if #random ~= 32 then return nil, "truncated random" end

  session, off = wire.vec(s, off, 1)
  if not session then return nil, "truncated session id" end

  local suitebytes
  suitebytes, off = wire.vec(s, off, 2)
  if not suitebytes then return nil, "truncated cipher suites" end
  suites = {}
  for i = 1, #suitebytes, 2 do
    suites[#suites + 1] = wire.int(suitebytes, i, 2)
  end

  comp, off = wire.vec(s, off, 1)
  if not comp then return nil, "truncated compression" end

  local extbytes
  extbytes, off = wire.vec(s, off, 2)
  if not extbytes then return nil, "truncated extensions" end
  local err
  exts, err = wire.extensions(extbytes)
  if not exts then return nil, err end

  return {
    version = version,
    random = random,
    session_id = session,
    suites = suites,
    compression = comp,
    ext = exts,
  }
end

local function u16list(s)
  local out = {}
  for i = 1, #s, 2 do out[#out + 1] = wire.int(s, i, 2) end
  return out
end

-- The extensions a server has to read, unpacked. Each returns nil when
-- the extension is absent, which for supported_versions and key_share
-- means the peer is not offering TLS 1.3 at all.
function M.supported_versions(ch)
  local e = ch.ext[M.EXT.supported_versions]
  if not e then return nil end
  return u16list(select(1, wire.vec(e, 1, 1)) or "")
end

function M.supported_groups(ch)
  local e = ch.ext[M.EXT.supported_groups]
  if not e then return nil end
  return u16list(select(1, wire.vec(e, 1, 2)) or "")
end

function M.signature_algorithms(ch)
  local e = ch.ext[M.EXT.signature_algorithms]
  if not e then return nil end
  return u16list(select(1, wire.vec(e, 1, 2)) or "")
end

-- key_share in a ClientHello is a vector of { group, key }, in the
-- client's order of preference. A server that supports one group takes
-- the first entry naming it and ignores the rest.
function M.key_shares(ch)
  local e = ch.ext[M.EXT.key_share]
  if not e then return nil end
  local body = select(1, wire.vec(e, 1, 2))
  if not body then return nil end

  local out, off = {}, 1
  while off <= #body do
    local group, key
    group, off = wire.int(body, off, 2)
    if not group then break end
    key, off = wire.vec(body, off, 2)
    if not key then break end
    out[#out + 1] = { group = group, key = key }
  end
  return out
end

function M.alpn(ch)
  local e = ch.ext[M.EXT.alpn]
  if not e then return nil end
  local body = select(1, wire.vec(e, 1, 2))
  if not body then return nil end

  local out, off = {}, 1
  while off <= #body do
    local p
    p, off = wire.vec(body, off, 1)
    if not p then break end
    out[#out + 1] = p
  end
  return out
end

function M.server_name(ch)
  local e = ch.ext[M.EXT.server_name]
  if not e then return nil end
  local list = select(1, wire.vec(e, 1, 2))
  if not list or #list < 3 then return nil end
  return (select(1, wire.vec(list, 2, 2)))
end

function M.has(list, want)
  for _, v in ipairs(list or {}) do
    if v == want then return true end
  end
  return false
end

-- ServerHello.
--
-- legacy_version is 0x0303 and legacy_compression_method is 0, always;
-- the session ID is the client's, echoed; and the real version travels
-- in supported_versions. TLS 1.3 says so precisely because a middlebox
-- that learned TLS 1.2 by rote will otherwise drop the connection.
function M.server_hello(random, session_id, suite, group, key)
  local exts = wire.wextensions {
    { type = M.EXT.supported_versions, body = wire.wint(M.TLS13, 2) },
    { type = M.EXT.key_share,
      body = wire.wint(group, 2) .. wire.wvec(key, 2) },
  }

  return wire.handshake(M.SERVER_HELLO, table.concat {
    wire.wint(0x0303, 2),
    random,
    wire.wvec(session_id, 1),
    wire.wint(suite, 2),
    wire.wint(0, 1),
    exts,
  })
end

return M
