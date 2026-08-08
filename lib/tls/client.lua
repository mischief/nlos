-- The TLS 1.3 client handshake: the mirror of tls/server.lua, and
-- sans-io in the same way.
--
-- Two transports carry it. QUIC puts the messages in CRYPTO frames.
-- TCP puts them in records. The transport differs here in two places,
-- both marked below. A caller that supplies transport_params gets the
-- QUIC behaviour.
--
-- ---- what this does and does not authenticate ----
--
-- It verifies the server's Finished, which is a real check: the
-- verify_data is an HMAC under a key derived from the handshake secret,
-- so it proves the peer performed the same key schedule over the same
-- transcript with the same ECDHE output. What it proves is that the
-- peer performed the exchange, not who the peer is.
--
-- Who the peer is comes from CertificateVerify, and checking it is the
-- caller's `verify` function: this file hands over the chain and the
-- signature and does not judge them. tls/tofu.lua is that function for
-- a client that pins keys. The default refuses, and `insecure = true`
-- is what a caller must pass to get an unauthenticated connection
-- anyway.

local hkdf = require "crypto.hkdf"
local sha256 = require "crypto.sha256"
local x25519 = require "crypto.x25519"
local util = require "crypto.util"
local wire = require "tls.wire"
local hello = require "tls.hello"
local keys = require "tls.keys"

local M = {}

local srep = string.rep
local ZEROS = srep("\0", 32)

-- the schedule, shared with the server half. Reaching it through
-- tls/server.lua would load the whole server into a client that only
-- ever connects.
local derive = keys.derive

local C = {}
C.__index = C

-- new{ rand, alpn, transport_params, server_name, verify, insecure }
--
-- transport_params is QUIC's. A TCP caller omits it. alpn is one
-- protocol name or a list of them; the selection lands in
-- `selected_alpn`.
function M.new(opts)
  return setmetatable({
    rand = assert(opts.rand, "tls: needs rand"),
    alpn = opts.alpn,
    tparams = opts.transport_params,
    server_name = opts.server_name,
    verify = opts.verify,
    insecure = opts.insecure or false,
    transcript = {},
    state = "start",
  }, C)
end

function C:hash()
  return sha256.hash(table.concat(self.transcript))
end

function C:add(msg)
  self.transcript[#self.transcript + 1] = msg
end

-- The ClientHello, and the ephemeral scalar it commits to.
--
-- The signature_algorithms list is exactly what tls/tofu.lua can check:
-- ed25519, ecdsa_secp256r1_sha256, and RSA-PSS over each of the three
-- SHA-2 sizes. A server picks from this list and signs with what it
-- picked, so an entry that cannot be verified is a connection that
-- fails after the work rather than before it.
function C:client_hello()
  self.scalar = self.rand(32)
  local share = x25519.scalarmult_base(self.scalar)

  local sigalgs = {}
  for _, a in ipairs { hello.ED25519, hello.ECDSA_P256,
                       0x0804, 0x0805, 0x0806 } do
    sigalgs[#sigalgs + 1] = wire.wint(a, 2)
  end

  local exts = {
    { type = hello.EXT.supported_versions,
      body = wire.wvec(wire.wint(hello.TLS13, 2), 1) },
    { type = hello.EXT.supported_groups,
      body = wire.wvec(wire.wint(hello.X25519, 2), 2) },
    { type = hello.EXT.signature_algorithms,
      body = wire.wvec(table.concat(sigalgs), 2) },
    { type = hello.EXT.key_share,
      body = wire.wvec(wire.wint(hello.X25519, 2) .. wire.wvec(share, 2), 2) },
  }
  if self.tparams then
    exts[#exts + 1] = { type = hello.EXT.quic_transport_parameters,
                        body = self.tparams }
  end
  -- ALPN: one protocol or a list of them, in the caller's order of
  -- preference. The server picks one and names it in
  -- EncryptedExtensions.
  if self.alpn then
    local names = {}
    for _, p in ipairs(type(self.alpn) == "table" and self.alpn
                                                  or { self.alpn }) do
      names[#names + 1] = wire.wvec(p, 1)
    end
    exts[#exts + 1] = { type = hello.EXT.alpn,
                        body = wire.wvec(table.concat(names), 2) }
  end
  if self.server_name then
    -- server_name_list of one host_name entry, type 0.
    exts[#exts + 1] = {
      type = hello.EXT.server_name,
      body = wire.wvec("\0" .. wire.wvec(self.server_name, 2), 2),
    }
  end

  -- The session id is empty for QUIC and 32 random bytes for TCP. A
  -- non-empty id selects compatibility mode (RFC 8446 D.4). In that
  -- mode the handshake looks like a TLS 1.2 resumption to a middlebox.
  -- The dummy ChangeCipherSpec record completes the disguise. RFC 9001
  -- 8.4 forbids the field over QUIC.
  self.session_id = self.tparams and "" or self.rand(32)

  local msg = wire.handshake(hello.CLIENT_HELLO, table.concat {
    wire.wint(0x0303, 2),
    self.rand(32),
    wire.wvec(self.session_id, 1),
    wire.wvec(wire.wint(keys.SUITE, 2), 2),
    wire.wvec("\0", 1),
    wire.wextensions(exts),
  })

  self:add(msg)
  self.state = "wait_server_hello"
  return msg
end

-- The ServerHello, from which the handshake secrets follow.
function C:server_hello(msg)
  local m = wire.read_handshake(msg)
  if not m or m.type ~= hello.SERVER_HELLO then
    return nil, "expected a ServerHello"
  end

  local s = m.body
  local off = 3 + 32                    -- legacy_version, random
  local session, suite, exts
  session, off = wire.vec(s, off, 1)
  if not session then return nil, "truncated session id" end
  suite, off = wire.int(s, off, 2)
  off = off + 1                         -- legacy_compression_method
  local extbytes
  extbytes, off = wire.vec(s, off, 2)
  if not extbytes then return nil, "truncated extensions" end
  exts = wire.extensions(extbytes)
  if not exts then return nil, "bad extensions" end

  if suite ~= keys.SUITE then
    return nil, ("server chose cipher suite 0x%04x"):format(suite)
  end

  local sv = exts[hello.EXT.supported_versions]
  if not sv or wire.int(sv, 1, 2) ~= hello.TLS13 then
    return nil, "server did not select TLS 1.3"
  end

  -- A HelloRetryRequest is a ServerHello with a magic random; without
  -- support for it, the only honest thing is to say so.
  local ks = exts[hello.EXT.key_share]
  if not ks then return nil, "no key share (HelloRetryRequest?)" end
  local group = wire.int(ks, 1, 2)
  local peer = wire.vec(ks, 3, 2)
  if group ~= hello.X25519 or not peer or #peer ~= 32 then
    return nil, "server key share is not x25519"
  end

  self:add(msg)

  local shared = x25519.shared(self.scalar, peer)
  local early = hkdf.extract(sha256, nil, ZEROS)
  local hs = hkdf.extract(sha256, derive(early, "derived", sha256.hash("")),
                          shared)
  local th = self:hash()
  self.c_hs = derive(hs, "c hs traffic", th)
  self.s_hs = derive(hs, "s hs traffic", th)
  self.hs_secret = hs
  self.state = "wait_encrypted_extensions"
  return true
end

-- The server's Handshake-space flight: EncryptedExtensions, Certificate,
-- CertificateVerify, Finished. Returns the client's Finished message, or
-- nil and a reason.
function C:server_flight(bytes)
  local off = 1
  local seen = {}

  while off <= #bytes do
    local m, next_off = wire.read_handshake(bytes, off)
    if not m then return nil, "incomplete server flight" end

    if m.type == hello.ENCRYPTED_EXTENSIONS then
      local ext = wire.extensions((wire.vec(m.body, 1, 2)) or "")
      self.peer_transport_params = ext
        and ext[hello.EXT.quic_transport_parameters]
      if ext and ext[hello.EXT.alpn] then
        local list = wire.vec(ext[hello.EXT.alpn], 1, 2)
        self.selected_alpn = list and (wire.vec(list, 1, 1))
      end
    elseif m.type == hello.CERTIFICATE then
      -- certificate_request_context, then a list of { cert, extensions }.
      local ctx, p = wire.vec(m.body, 1, 1)
      local list = wire.vec(m.body, p, 3)
      self.chain = {}
      local q = 1
      while list and q <= #list do
        local c
        c, q = wire.vec(list, q, 3)
        if not c then break end
        self.chain[#self.chain + 1] = c
        local _
        _, q = wire.vec(list, q, 2)     -- per-certificate extensions
      end
    elseif m.type == hello.CERTIFICATE_REQUEST then
      -- The context is echoed in the answer. RFC 8446 4.3.2 makes it
      -- zero length outside post-handshake authentication.
      self.cert_request = (wire.vec(m.body, 1, 1)) or ""
    elseif m.type == hello.CERTIFICATE_VERIFY then
      self.cert_verify = {
        algorithm = wire.int(m.body, 1, 2),
        signature = (wire.vec(m.body, 3, 2)),
        -- What the signature covers: the transcript up to but not
        -- including this message.
        transcript_hash = self:hash(),
      }
    elseif m.type == hello.FINISHED then
      local want = keys.finished(self.s_hs, self:hash())
      if not util.ct_eq(m.body, want) then
        return nil, "server Finished does not verify"
      end
      seen.finished = true
    end

    seen[m.type] = true
    self:add(m.body and bytes:sub(off, next_off - 1))
    off = next_off
  end

  if not seen.finished then return nil, "server flight is incomplete" end

  -- Authentication, such as it is. The default refuses: a caller that
  -- has no verifier and has not said `insecure` should not get a
  -- connection it might mistake for an authenticated one.
  if self.verify then
    local ok, why = self.verify(self.chain, self.cert_verify)
    if not ok then return nil, "certificate rejected: " .. tostring(why) end
  elseif not self.insecure then
    return nil, "no certificate verifier and insecure not set"
  end

  -- Application secrets are bound to the transcript through the server's
  -- Finished, and the client's Finished is computed over the same one.
  local master = hkdf.extract(sha256,
                              derive(self.hs_secret, "derived",
                                     sha256.hash("")), ZEROS)
  local th = self:hash()
  self.c_ap = derive(master, "c ap traffic", th)
  self.s_ap = derive(master, "s ap traffic", th)

  -- RFC 8446 4.4.2: a client that was asked for a certificate answers,
  -- and an empty certificate_list is the answer when it has none. The
  -- message is required even so; leaving it out is an unexpected
  -- message to the server, not a declined option.
  local out = {}
  if self.cert_request then
    local cert = wire.handshake(hello.CERTIFICATE,
                                wire.wvec(self.cert_request, 1) ..
                                wire.wvec("", 3))
    self:add(cert)
    out[#out + 1] = cert
  end

  local fin = wire.handshake(hello.FINISHED,
                             keys.finished(self.c_hs, self:hash()))
  self:add(fin)
  out[#out + 1] = fin
  self.state = "done"
  return table.concat(out)
end

return M
