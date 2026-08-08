-- RSA signature verification, RFC 8017.
--
-- What needs it: TLS CertificateVerify from a server with an RSA key,
-- which is most of them. Two schemes, because TLS 1.3 signs with PSS
-- and certificates are still signed with PKCS #1 v1.5.
--
-- Verification only, with a public exponent and public data, so nothing
-- here is constant time and nothing here holds a secret. There is no
-- private operation at all: this cannot sign.
--
-- The check that matters in both schemes is the encoding. A modular
-- exponentiation always produces something; whether that something has
-- the exact shape the scheme demands is the signature. Every step of
-- that shape is checked below, including the padding bytes, because a
-- verifier that skips one accepts forgeries.

local bn = require "crypto.bignum"
local util = require "crypto.util"

local M = {}

local srep, ssub, sbyte, schar = string.rep, string.sub, string.byte,
                                 string.char

-- MGF1, RFC 8017 B.2.1: the hash of the seed and a counter, repeated
-- until enough bytes exist.
local function mgf1(hash, seed, len)
  local out, i = {}, 0
  while #table.concat(out) < len do
    out[#out + 1] = hash.hash(seed .. string.pack(">I4", i))
    i = i + 1
  end
  return ssub(table.concat(out), 1, len)
end

M.mgf1 = mgf1

local function xor(a, b)
  local out = {}
  for i = 1, #a do out[i] = schar(sbyte(a, i) ~ sbyte(b, i)) end
  return table.concat(out)
end

-- key(n, e) -> a public key, with the modulus as big-endian bytes and
-- the exponent as an integer or as bytes.
function M.key(n, e)
  local m = bn.modulus(n)
  if not m then return nil, "bad RSA modulus" end
  if type(e) == "number" then
    local bytes = {}
    while e > 0 do
      table.insert(bytes, 1, schar(e & 0xff))
      e = e >> 8
    end
    e = table.concat(bytes)
  end
  if #e == 0 then return nil, "bad RSA exponent" end
  return { m = m, e = e, size = #n }
end

-- The public operation: s^e mod n, back to bytes of the modulus's own
-- length. RFC 8017 5.2.2.
local function public(key, sig)
  if #sig ~= key.size then return nil, "signature is not the modulus size" end
  local s = key.m:from(sig)
  if not s or key.m:cmp(s, key.m.m) >= 0 then
    return nil, "signature is not less than the modulus"
  end
  return key.m:to_bytes(key.m:exp(s, key.e), key.size)
end

M.public = public

-- verify_pss(key, hash, message, signature) -> true, or false and a
-- reason. RFC 8017 8.1.2 with the salt length equal to the digest
-- length, which is what TLS 1.3 requires (RFC 8446 4.2.3).
function M.verify_pss(key, hash, message, sig)
  local hlen = hash.digest_len
  local slen = hlen

  -- emBits is one less than the modulus's bit length, so emLen can be
  -- one byte shorter than the modulus. RSA moduli in use are a whole
  -- number of bytes with the top bit set, which makes emLen the size
  -- and leaves 1 bit to mask off.
  local embits = key.size * 8 - 1
  local emlen = (embits + 7) // 8

  local em, err = public(key, sig)
  if not em then return false, err end
  if #em > emlen then em = ssub(em, #em - emlen + 1) end

  local mhash = hash.hash(message)
  if emlen < hlen + slen + 2 then return false, "modulus is too small" end
  if sbyte(em, emlen) ~= 0xbc then return false, "bad PSS trailer" end

  local masked = ssub(em, 1, emlen - hlen - 1)
  local h = ssub(em, emlen - hlen, emlen - 1)

  -- The bits above emBits must be zero, in the encoded message and
  -- again in DB after unmasking.
  local spare = 8 * emlen - embits
  local top = (0xff << (8 - spare)) & 0xff
  if sbyte(masked, 1) & top ~= 0 then return false, "bad PSS padding" end

  local db = xor(masked, mgf1(hash, h, #masked))
  db = schar(sbyte(db, 1) & ~top & 0xff) .. ssub(db, 2)

  local zeros = emlen - hlen - slen - 2
  if ssub(db, 1, zeros) ~= srep("\0", zeros) then
    return false, "bad PSS padding"
  end
  if sbyte(db, zeros + 1) ~= 0x01 then return false, "bad PSS padding" end

  local salt = ssub(db, #db - slen + 1)
  local prime = hash.hash(srep("\0", 8) .. mhash .. salt)
  if not util.ct_eq(h, prime) then return false, "signature does not verify" end
  return true
end

-- The DigestInfo prefixes of RFC 8017 9.2, notes 1: an ASN.1 SEQUENCE
-- naming the hash, then the digest. They are constants rather than an
-- encoder because there are three of them and no other shape is legal.
M.DIGESTINFO = {
  [32] = util.unhex "3031300d060960864801650304020105000420",   -- SHA-256
  [48] = util.unhex "3041300d060960864801650304020205000430",   -- SHA-384
  [64] = util.unhex "3051300d060960864801650304020305000440",   -- SHA-512
}

-- verify_pkcs1(key, hash, message, signature) -> true, or false and a
-- reason. RFC 8017 8.2.2: the comparison is against the whole encoded
-- message, which is what makes the padding part of the check.
function M.verify_pkcs1(key, hash, message, sig)
  local em, err = public(key, sig)
  if not em then return false, err end

  local prefix = M.DIGESTINFO[hash.digest_len]
  if not prefix then return false, "no DigestInfo for this hash" end

  local t = prefix .. hash.hash(message)
  if key.size < #t + 11 then return false, "modulus is too small" end

  local want = "\0\1" .. srep("\xff", key.size - #t - 3) .. "\0" .. t
  if not util.ct_eq(em, want) then return false, "signature does not verify" end
  return true
end

return M
