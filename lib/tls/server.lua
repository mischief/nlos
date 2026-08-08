-- The TLS 1.3 server handshake, RFC 8446 with RFC 9001's changes.
--
-- Sans-io twice over: this produces handshake *messages* and traffic
-- secrets, and knows nothing about records, packets or CRYPTO frames.
-- QUIC removes the TLS record layer entirely (RFC 9001 4), so what would
-- be a record boundary is quic.conn's problem and nothing is buffered
-- here that the transport has not already reassembled. Over TCP the
-- caller frames these messages with tls/record.lua.
--
-- One algorithm in every slot, as everywhere in this tree:
--
--   cipher suite   TLS_CHACHA20_POLY1305_SHA256
--   group          x25519
--   signature      ed25519
--
-- msquic offers all three, which is what made them a defensible choice
-- rather than a convenient one; anything else is refused with an alert
-- rather than negotiated down.
--
-- ---- what is not here ----
--
-- No session tickets, no 0-RTT, no HelloRetryRequest, no client
-- certificates, no X.509 parsing. The last is worth naming: a server
-- only ever *sends* a certificate, so the chain is an opaque blob it was
-- handed. Verifying one is client work and needs an ASN.1 parser this
-- tree does not have.

local hkdf = require "crypto.hkdf"
local hmac = require "crypto.hmac"
local sha256 = require "crypto.sha256"
local x25519 = require "crypto.x25519"
local ed25519 = require "crypto.ed25519"
local util = require "crypto.util"
local wire = require "tls.wire"
local hello = require "tls.hello"

local M = {}

local srep = string.rep

M.SUITE = hello.CHACHA20_POLY1305_SHA256
M.KEY_LEN = 32                          -- of the AEAD the suite names

-- RFC 8446 4.4.3: the signature covers 64 spaces, a context string, a
-- zero byte and the transcript hash. The padding exists so that a
-- signature made here can never be mistaken for one made over a
-- certificate, which is what a cross-protocol attack would want.
local SIG_CONTEXT = srep("\32", 64) .. "TLS 1.3, server CertificateVerify\0"

local S = {}
S.__index = S

-- new{ seed, cert, transport_params, alpn, rand }
--
--   seed              32-byte Ed25519 private key seed
--   cert              the certificate, DER, as bytes: opaque here
--   transport_params  encoded quic.tparams, ours; absent over TCP
--   alpn              the protocol to select, if the client offers it
--   request_certificate  ask the client for a certificate. The answer
--                     is not checked: there is no chain to check it
--                     against. It exercises the message exchange.
--   rand(n)           entropy
function M.new(opts)
  return setmetatable({
    seed = assert(opts.seed, "tls: needs an ed25519 seed"),
    cert = assert(opts.cert, "tls: needs a certificate"),
    tparams = opts.transport_params,
    alpn = opts.alpn,
    want_client_cert = opts.request_certificate or false,
    rand = assert(opts.rand, "tls: needs rand"),
    transcript = {},
    state = "wait_client_hello",
  }, S)
end

function S:hash()
  return sha256.hash(table.concat(self.transcript))
end

function S:add(msg)
  self.transcript[#self.transcript + 1] = msg
end

-- The key schedule, RFC 8446 7.1. Each secret is derived from the one
-- above it, and "derived" between stages is what keeps a secret from
-- being usable as the input of the stage that produced it.
local ZEROS = srep("\0", 32)

local function derive(secret, label, transcript_hash)
  return hkdf.expand_label(sha256, secret, label, transcript_hash, 32)
end

-- The verify_data of a Finished message: an HMAC under a key derived
-- from the traffic secret, over the transcript so far. Not a signature:
-- both ends already hold the traffic secret, so this proves the key
-- schedule agrees rather than proving identity.
local function finished(secret, transcript_hash)
  local key = hkdf.expand_label(sha256, secret, "finished", "", 32)
  return hmac.auth(sha256, key, transcript_hash)
end

M.finished = finished

-- accept(client_hello_message) -> flights, or nil, alert, reason
--
-- `client_hello_message` is the complete handshake message, header and
-- all, because that is what goes into the transcript. The return is the
-- two flights a server sends and the secrets that protect them:
--
--   initial    ServerHello, which travels in the Initial packet space
--   handshake  EncryptedExtensions .. Finished, in the Handshake space
--
-- The caller decides how they are packetised; that is exactly the split
-- RFC 9001 4.1 describes.
function S:accept(msg)
  local m = wire.read_handshake(msg)
  if not m or m.type ~= hello.CLIENT_HELLO then
    return nil, 10, "expected a ClientHello"       -- unexpected_message
  end

  local ch, err = hello.parse_client_hello(m.body)
  if not ch then return nil, 50, err end           -- decode_error

  if not hello.has(hello.supported_versions(ch), hello.TLS13) then
    return nil, 70, "no TLS 1.3"                   -- protocol_version
  end
  if not hello.has(ch.suites, M.SUITE) then
    return nil, 40, "no TLS_CHACHA20_POLY1305_SHA256"  -- handshake_failure
  end
  if not hello.has(hello.signature_algorithms(ch), hello.ED25519) then
    return nil, 40, "no ed25519"
  end

  -- The client's key share for our one group. A client that offered the
  -- group but sent no share for it would need a HelloRetryRequest, which
  -- is not implemented: refuse rather than pretend.
  local peer
  for _, ks in ipairs(hello.key_shares(ch) or {}) do
    if ks.group == hello.X25519 and #ks.key == 32 then peer = ks.key end
  end
  if not peer then return nil, 40, "no x25519 key share" end

  -- A server with transport parameters of its own is a QUIC endpoint,
  -- and RFC 9001 8.2 requires the client to send them too. Over TCP
  -- neither end has any.
  local ctp = ch.ext[hello.EXT.quic_transport_parameters]
  if self.tparams and not ctp then
    return nil, 109, "no transport parameters"     -- missing_extension
  end

  local alpn_ok = not self.alpn or hello.has(hello.alpn(ch) or {}, self.alpn)
  if not alpn_ok then return nil, 120, "no shared ALPN" end        -- no_application_protocol

  self.client_hello = ch
  self.client_transport_params = ctp
  self:add(msg)

  -- Our ephemeral share. A fresh scalar per connection is the whole of
  -- the forward secrecy claim.
  local scalar = self.rand(32)
  local share = x25519.scalarmult_base(scalar)
  local shared = x25519.shared(scalar, peer)

  local sh = hello.server_hello(self.rand(32), ch.session_id, M.SUITE,
                                hello.X25519, share)
  self:add(sh)

  -- Handshake secrets, and the transcript through the ServerHello is
  -- what they are bound to.
  local early = hkdf.extract(sha256, nil, ZEROS)
  local hs = hkdf.extract(sha256, derive(early, "derived", sha256.hash("")),
                          shared)
  local th = self:hash()
  self.c_hs = derive(hs, "c hs traffic", th)
  self.s_hs = derive(hs, "s hs traffic", th)
  self.hs_secret = hs

  -- The rest of the flight, which the Handshake keys protect.
  local exts = {}
  if self.tparams then
    exts[#exts + 1] = { type = hello.EXT.quic_transport_parameters,
                        body = self.tparams }
  end
  if self.alpn then
    exts[#exts + 1] = { type = hello.EXT.alpn,
                        body = wire.wvec(wire.wvec(self.alpn, 1), 2) }
  end
  local ee = wire.handshake(hello.ENCRYPTED_EXTENSIONS, wire.wextensions(exts))
  self:add(ee)

  -- CertificateRequest, when the caller asks for one. The context is
  -- empty outside post-handshake authentication (RFC 8446 4.3.2), and
  -- signature_algorithms is the one extension a request must carry.
  local cr = ""
  if self.want_client_cert then
    cr = wire.handshake(hello.CERTIFICATE_REQUEST, table.concat {
      wire.wvec("", 1),
      wire.wextensions {
        { type = hello.EXT.signature_algorithms,
          body = wire.wvec(wire.wint(hello.ED25519, 2), 2) },
      },
    })
    self:add(cr)
  end

  -- Certificate: a request context (empty, since this is not a response
  -- to a CertificateRequest), then a list of { cert, extensions }.
  local cert = wire.handshake(hello.CERTIFICATE, table.concat {
    wire.wvec("", 1),
    wire.wvec(wire.wvec(self.cert, 3) .. wire.wvec("", 2), 3),
  })
  self:add(cert)

  local sig = ed25519.sign(self.seed, SIG_CONTEXT .. self:hash())
  local cv = wire.handshake(hello.CERTIFICATE_VERIFY,
                            wire.wint(hello.ED25519, 2) .. wire.wvec(sig, 2))
  self:add(cv)

  local fin = wire.handshake(hello.FINISHED,
                             finished(self.s_hs, self:hash()))
  self:add(fin)

  -- Application secrets are bound to the transcript through the server's
  -- Finished: everything the server said is covered before any
  -- application data can be protected.
  local master = hkdf.extract(sha256,
                              derive(hs, "derived", sha256.hash("")), ZEROS)
  local th2 = self:hash()
  self.c_ap = derive(master, "c ap traffic", th2)
  self.s_ap = derive(master, "s ap traffic", th2)

  -- The client's Finished is verified against the transcript as it
  -- stands now, before its own message is added.
  self.expect_client_finished = finished(self.c_hs, self:hash())
  self.state = "wait_finished"

  return {
    initial = sh,
    handshake = ee .. cr .. cert .. cv .. fin,
  }
end

-- The client's last flight: a Certificate when one was asked for, then
-- Finished. After this the handshake is confirmed and the application
-- keys are in use both ways.
function S:client_finished(msg)
  local m, off = wire.read_handshake(msg)
  if not m then return nil, 50, "truncated client flight" end

  -- A requested certificate is answered, and an empty certificate_list
  -- is a valid answer. This server asks for one to see the message, not
  -- to authenticate anybody: it has nothing to check a chain against.
  if m.type == hello.CERTIFICATE then
    if not self.want_client_cert then
      return nil, 10, "unexpected Certificate"     -- unexpected_message
    end
    self:add(msg:sub(1, off - 1))
    m, off = wire.read_handshake(msg, off)
    if not m then return nil, 50, "truncated client flight" end
  elseif self.want_client_cert then
    return nil, 116, "no Certificate"              -- certificate_required
  end

  if m.type ~= hello.FINISHED then
    return nil, 10, "expected Finished"
  end
  if not util.ct_eq(m.body, finished(self.c_hs, self:hash())) then
    return nil, 51, "Finished does not verify"     -- decrypt_error
  end
  self:add(msg:sub(1, off - 1))
  self.state = "done"
  return true
end

return M
