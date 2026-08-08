-- Trust on first use for TLS, the way SSH trusts a host key.
--
-- A `verify` function for tls.conn, built from three callbacks the
-- caller supplies: what is known about a host, how to learn something
-- new, and how to ask. There is no root store, no chain building, no
-- name matching and no clock. What is remembered is a hash of the
-- leaf's SubjectPublicKeyInfo, so a certificate renewed under the same
-- key does not ask again.
--
-- Two rules, both from SSH:
--
--   * An unknown host is a question, and `ask` answers it. Without an
--     `ask` an unknown host is refused.
--   * A known host whose key changed is refused. It is never a
--     question, because the answer a user gives under a
--     man-in-the-middle attack is the wrong one.
--
-- ---- why the signature check is here ----
--
-- A certificate is public. Anyone can present a copy of the real
-- server's certificate, and a pin on its key would match. What cannot
-- be copied is CertificateVerify: a signature, under that key, over the
-- handshake transcript. Checking it is what turns the pin into evidence
-- about the peer, so this module refuses any signature algorithm it
-- cannot check rather than pinning without one.
--
-- What this still does not do is decide whether a key deserves the name
-- on it. That is what a certificate authority is for, and there is none
-- here: the first connection is trusted, exactly as `ssh` trusts the
-- first host key.

local sha256 = require "crypto.sha256"
local sha384 = require "crypto.sha384"
local sha512 = require "crypto.sha512"
local ed25519 = require "crypto.ed25519"
local p256 = require "crypto.p256"
local rsa = require "crypto.rsa"
local cert = require "x509.cert"
local der = require "x509.der"

local M = {}

local srep = string.rep

-- RFC 8446 4.4.3: 64 spaces, a context string and a zero byte, then the
-- transcript hash. The padding is what keeps this signature from being
-- mistaken for one made over a certificate.
local CONTEXT = srep("\32", 64) .. "TLS 1.3, server CertificateVerify\0"

M.ED25519 = 0x0807
M.ECDSA_P256_SHA256 = 0x0403

-- RFC 8446 4.2.3: TLS 1.3 signs with PSS and never with PKCS #1 v1.5,
-- whatever the certificate's own signature uses. rsae and pss_pss
-- differ in the key's OID, not in the operation.
M.RSA_PSS = {
  [0x0804] = sha256, [0x0805] = sha384, [0x0806] = sha512,  -- rsae
  [0x0809] = sha256, [0x080a] = sha384, [0x080b] = sha512,  -- pss
}

-- The two INTEGERs of an ECDSA signature, each padded to 32 bytes.
-- RFC 3279 2.2.3 gives the SEQUENCE, and DER writes each integer in the
-- fewest bytes, so both need padding back out.
local function ecdsa_rs(sig)
  local seq = der.expect(sig, 1, 0x30)
  local kids = seq and der.children(seq)
  if not kids or #kids ~= 2 then return nil, "bad ECDSA signature" end

  local out = {}
  for i = 1, 2 do
    local v = der.integer(kids[i])
    if type(v) == "number" then
      if v < 0 then return nil, "negative ECDSA signature value" end
      v = ("\0"):rep(8) .. string.pack(">I8", v)
    end
    if #v > 32 then return nil, "ECDSA signature value is too long" end
    out[i] = ("\0"):rep(32 - #v) .. v
  end
  return out[1], out[2]
end

-- check_signature(leaf, cert_verify) -> true, or nil and a reason.
function M.check_signature(leaf, cert_verify)
  if not cert_verify then return nil, "no CertificateVerify" end
  local message = CONTEXT .. cert_verify.transcript_hash
  local key = leaf.key

  if cert_verify.algorithm == M.ED25519 then
    if key.algorithm.name ~= "Ed25519" then
      return nil, "the certificate does not hold an Ed25519 key"
    end
    if not ed25519.verify(key.bits, message, cert_verify.signature) then
      return nil, "the Ed25519 signature does not verify"
    end
    return true
  end

  if cert_verify.algorithm == M.ECDSA_P256_SHA256 then
    if key.algorithm.name ~= "id-ecPublicKey" or key.curve ~= "prime256v1" then
      return nil, "the certificate does not hold a P-256 key"
    end
    local r, s = ecdsa_rs(cert_verify.signature)
    if not r then return nil, s end
    local ok, why = p256.verify(key.bits, sha256.hash(message), r, s)
    if not ok then return nil, why end
    return true
  end

  local hash = M.RSA_PSS[cert_verify.algorithm]
  if hash then
    if key.algorithm.name ~= "rsaEncryption" then
      return nil, "the certificate does not hold an RSA key"
    end

    -- The key is an RSAPublicKey, SEQUENCE { modulus, publicExponent }.
    local seq = der.expect(key.bits, 1, 0x30)
    local kids = seq and der.children(seq)
    if not kids or #kids ~= 2 then return nil, "bad RSA public key" end
    local n, e = der.integer(kids[1]), der.integer(kids[2])
    if type(n) ~= "string" then return nil, "RSA modulus is too small" end

    local pub, why = rsa.key(n, e)
    if not pub then return nil, why end

    local ok
    ok, why = rsa.verify_pss(pub, hash, message, cert_verify.signature)
    if not ok then return nil, why end
    return true
  end

  return nil, ("signature algorithm 0x%04x cannot be checked")
    :format(cert_verify.algorithm or 0)
end

-- The name a host is remembered under, and what is remembered about it:
-- the SHA-256 of the leaf's SubjectPublicKeyInfo, as lowercase hex.
function M.fingerprint(leaf)
  return (sha256.hash(leaf.key.spki_raw):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

-- new{ host, known, learn, ask } -> a verify function for tls.conn.
--
--   known(host)        -> the fingerprint remembered for this host, or nil
--   learn(host, fp)    -> remember one; called only after `ask` agrees
--   ask(host, fp, leaf)-> true to accept an unknown host
--
-- `leaf` is the parsed certificate, so a caller that wants to show a
-- subject or a validity window to a user has it.
function M.new(opts)
  local host = assert(opts.host, "tofu: needs a host")

  return function(chain, cert_verify)
    if not chain or not chain[1] then return nil, "no certificate" end

    local leaf, err = cert.parse(chain[1])
    if not leaf then return nil, err end

    local ok, why = M.check_signature(leaf, cert_verify)
    if not ok then return nil, why end

    local fp = M.fingerprint(leaf)
    local seen = opts.known and opts.known(host)

    if seen then
      if seen ~= fp then
        return nil, ("the key for %s changed"):format(host)
      end
      return true
    end

    if not opts.ask then return nil, ("%s is not known"):format(host) end
    if not opts.ask(host, fp, leaf) then
      return nil, ("%s was not accepted"):format(host)
    end
    if opts.learn then opts.learn(host, fp) end
    return true
  end
end

return M
