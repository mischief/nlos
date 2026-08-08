-- HKDF (RFC 5869) and the TLS 1.3 labelled forms of it (RFC 8446 7.1),
-- which are what QUIC's key schedule is built from (RFC 9001 5.1).
--
-- Extract-then-expand, and the split matters to the caller rather than
-- only to the proof: a QUIC endpoint extracts once per connection from
-- the fixed Initial salt and then expands the same PRK into a key, an IV
-- and a header-protection key, so the two halves are separately useful.
--
-- Every function takes the hash module first. The cipher suite names the
-- hash -- SHA-256 for TLS_CHACHA20_POLY1305_SHA256 -- and nothing here
-- has any business assuming which one, since a suite with SHA-384 would
-- otherwise derive silently wrong keys rather than failing.

local hmac = require "crypto.hmac"

local M = {}

local spack, ssub, sconcat = string.pack, string.sub, table.concat

-- HKDF-Extract(salt, IKM) -> PRK. A nil or empty salt means HashLen
-- zeroes, per RFC 5869 2.2; the salt is the HMAC key, not the message.
function M.extract(hash, salt, ikm)
  if not salt or salt == "" then salt = string.rep("\0", hash.digest_len) end
  return hmac.auth(hash, salt, ikm)
end

-- HKDF-Expand(PRK, info, L) -> L bytes.
function M.expand(hash, prk, info, len)
  info = info or ""
  local n = (len + hash.digest_len - 1) // hash.digest_len
  -- The counter is one octet, so N > 255 is not representable and is an
  -- error rather than something to wrap around into a repeated block.
  assert(n <= 255, "hkdf: requested length too long")

  local out, t = {}, ""
  for i = 1, n do
    t = hmac.new(hash, prk):update(t):update(info):update(string.char(i)):final()
    out[i] = t
  end
  return ssub(sconcat(out), 1, len)
end

-- HkdfLabel, RFC 8446 7.1: uint16 length, opaque label<7..255> with the
-- "tls13 " prefix included in the length, opaque context<0..255>.
--
-- QUIC uses this structure unchanged, prefix included -- RFC 9001 5.1 is
-- explicit that the labels are TLS labels with QUIC-specific text, not a
-- separate encoding. RFC 9001 A.1 publishes the encoded bytes for the
-- four QUIC labels, which is what the spec suite checks this against.
function M.hkdf_label(label, context, len)
  label = "tls13 " .. label
  assert(#label <= 255 and #context <= 255, "hkdf: label or context too long")
  return spack(">I2s1s1", len, label, context)
end

-- HKDF-Expand-Label(Secret, Label, Context, Length).
function M.expand_label(hash, secret, label, context, len)
  return M.expand(hash, secret, M.hkdf_label(label, context or "", len), len)
end

-- Derive-Secret(Secret, Label, Messages): the context is the transcript
-- hash, not the transcript.
function M.derive_secret(hash, secret, label, messages)
  return M.expand_label(hash, secret, label, hash.hash(messages),
                        hash.digest_len)
end

return M
