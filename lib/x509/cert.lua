-- X.509 certificates, RFC 5280: the fields a TLS client has to look at.
--
--   Certificate ::= SEQUENCE {
--       tbsCertificate       TBSCertificate,
--       signatureAlgorithm   AlgorithmIdentifier,
--       signatureValue       BIT STRING }
--
-- The signature covers the *encoding* of tbsCertificate, so `tbs_raw` is
-- kept as the bytes that were read rather than re-encoded from the
-- parsed fields. Re-encoding is how a parser and a verifier end up
-- disagreeing about what was signed.
--
-- What is deliberately shallow: the distinguished names come back as a
-- list of { oid, value } and a printable form, not as a structure with
-- opinions about which attribute means what. Name *comparison* is
-- limited to the byte equality that chain building needs -- the full
-- RFC 4518 string preparation is a great deal of Unicode for a case that
-- does not arise between a certificate and its issuer's subject, which
-- were emitted by the same CA.

local der = require "x509.der"

local M = {}

local T = der.TAG

-- The OIDs this recognises. Everything else is carried by its dotted
-- number, which is what an unknown critical extension has to be judged
-- on anyway.
M.OID = {
  ["1.2.840.113549.1.1.1"] = "rsaEncryption",
  ["1.2.840.113549.1.1.11"] = "sha256WithRSAEncryption",
  ["1.2.840.113549.1.1.12"] = "sha384WithRSAEncryption",
  ["1.2.840.113549.1.1.13"] = "sha512WithRSAEncryption",
  ["1.2.840.10045.2.1"] = "id-ecPublicKey",
  ["1.2.840.10045.3.1.7"] = "prime256v1",
  ["1.3.132.0.34"] = "secp384r1",
  ["1.2.840.10045.4.3.2"] = "ecdsa-with-SHA256",
  ["1.2.840.10045.4.3.3"] = "ecdsa-with-SHA384",
  ["1.3.101.112"] = "Ed25519",
  ["2.5.4.3"] = "CN",
  ["2.5.4.6"] = "C",
  ["2.5.4.7"] = "L",
  ["2.5.4.8"] = "ST",
  ["2.5.4.10"] = "O",
  ["2.5.4.11"] = "OU",
  ["2.5.29.14"] = "subjectKeyIdentifier",
  ["2.5.29.15"] = "keyUsage",
  ["2.5.29.17"] = "subjectAltName",
  ["2.5.29.19"] = "basicConstraints",
  ["2.5.29.35"] = "authorityKeyIdentifier",
  ["2.5.29.37"] = "extKeyUsage",
}

local function name_of(oid)
  return M.OID[oid] or oid
end

-- AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }
local function algorithm(e)
  local kids = der.children(e)
  if not kids or #kids == 0 then return nil, "bad AlgorithmIdentifier" end
  local oid = der.oid(kids[1])
  if not oid then return nil, "bad algorithm oid" end
  return { oid = oid, name = name_of(oid), params = kids[2] }
end

-- Name ::= SEQUENCE OF SET OF AttributeTypeAndValue
local function parse_name(e)
  local rdns = der.children(e)
  if not rdns then return nil, "bad Name" end

  local attrs, parts = {}, {}
  for _, rdn in ipairs(rdns) do
    for _, atv in ipairs(der.children(rdn) or {}) do
      local kids = der.children(atv)
      if kids and #kids >= 2 then
        local oid = der.oid(kids[1])
        local value = kids[2].contents
        attrs[#attrs + 1] = { oid = oid, name = name_of(oid), value = value }
        parts[#parts + 1] = ("%s=%s"):format(name_of(oid), value)
      end
    end
  end

  return {
    attrs = attrs,
    text = table.concat(parts, ", "),
    -- The encoding, for comparison: an issuer matches a subject when the
    -- bytes match, which is what a CA that issued both guarantees.
    raw = e.raw,
  }
end

function M.name_get(name, want)
  for _, a in ipairs(name.attrs) do
    if a.name == want then return a.value end
  end
  return nil
end

-- SubjectAltName, the extension that actually decides whether a
-- certificate is for a host. The CN has not been authoritative for that
-- since RFC 2818 was replaced, and treating it as a fallback is how a
-- certificate for one name gets accepted for another.
local function parse_san(body)
  local seq = der.read(body)
  if not seq then return nil end

  local dns, ip = {}, {}
  for _, e in ipairs(der.children(seq) or {}) do
    -- Context tags: [2] dNSName, [7] iPAddress.
    if e.tag == 0x82 then
      dns[#dns + 1] = e.contents
    elseif e.tag == 0x87 then
      ip[#ip + 1] = e.contents
    end
  end
  return { dns = dns, ip = ip }
end

local function parse_basic_constraints(body)
  local seq = der.read(body)
  if not seq then return nil end
  local out = { ca = false }
  for _, e in ipairs(der.children(seq) or {}) do
    if e.tag == T.boolean then
      out.ca = e.contents:byte(1) ~= 0
    elseif e.tag == T.integer then
      out.path_len = der.integer(e)
    end
  end
  return out
end

local function parse_key_usage(body)
  local e = der.read(body)
  if not e or e.tag ~= T.bitstring then return nil end
  local unused = e.contents:byte(1) or 0
  local bits = e.contents:sub(2)
  local out = {}
  local names = { "digitalSignature", "nonRepudiation", "keyEncipherment",
                  "dataEncipherment", "keyAgreement", "keyCertSign",
                  "cRLSign", "encipherOnly", "decipherOnly" }
  for i, n in ipairs(names) do
    local byte = bits:byte((i - 1) // 8 + 1)
    if byte then
      local bit = 7 - ((i - 1) % 8)
      if (i - 1) < #bits * 8 - unused and (byte >> bit) & 1 == 1 then
        out[n] = true
      end
    end
  end
  return out
end

-- parse(der_bytes) -> certificate, or nil, reason
function M.parse(bytes)
  local cert, err = der.expect(bytes, 1, T.sequence)
  if not cert then return nil, err end

  local top = der.children(cert)
  if not top or #top < 3 then return nil, "bad Certificate" end

  local tbs, sigalg_e, sigval_e = top[1], top[2], top[3]
  local sigalg = algorithm(sigalg_e)
  if not sigalg then return nil, "bad signature algorithm" end
  local sig = der.bitstring(sigval_e)
  if not sig then return nil, "bad signature value" end

  local fields = der.children(tbs)
  if not fields then return nil, "bad TBSCertificate" end

  local i = 1
  local version = 1
  if fields[i] and fields[i].tag == 0xa0 then        -- [0] EXPLICIT version
    local v = der.read(fields[i].contents)
    version = (v and der.integer(v) or 0) + 1
    i = i + 1
  end

  local serial = fields[i]; i = i + 1
  local inner_alg = fields[i]; i = i + 1
  local issuer = fields[i]; i = i + 1
  local validity = fields[i]; i = i + 1
  local subject = fields[i]; i = i + 1
  local spki = fields[i]; i = i + 1

  if not spki then return nil, "TBSCertificate is missing fields" end

  local val = der.children(validity)
  if not val or #val < 2 then return nil, "bad Validity" end
  local not_before, not_after = der.time(val[1]), der.time(val[2])
  if not (not_before and not_after) then return nil, "bad validity dates" end

  -- SubjectPublicKeyInfo ::= SEQUENCE { algorithm, subjectPublicKey BIT STRING }
  local spki_kids = der.children(spki)
  if not spki_kids or #spki_kids < 2 then return nil, "bad SubjectPublicKeyInfo" end
  local keyalg = algorithm(spki_kids[1])
  local keybits = der.bitstring(spki_kids[2])
  if not (keyalg and keybits) then return nil, "bad public key" end

  local curve
  if keyalg.name == "id-ecPublicKey" and spki_kids[1] then
    local a = der.children(spki_kids[1])
    if a and a[2] then curve = name_of(der.oid(a[2]) or "") end
  end

  -- Extensions live in [3] EXPLICIT, last.
  local ext, critical_unknown = {}, {}
  for j = i, #fields do
    if fields[j].tag == 0xa3 then
      local seq = der.read(fields[j].contents)
      for _, e in ipairs(seq and der.children(seq) or {}) do
        local kids = der.children(e)
        if kids and #kids >= 2 then
          local oid = der.oid(kids[1])
          local critical = false
          local body = kids[#kids].contents
          if #kids == 3 then critical = kids[2].contents:byte(1) ~= 0 end
          local name = name_of(oid)
          ext[name] = { critical = critical, body = body, oid = oid }

          if name == "subjectAltName" then
            ext.san = parse_san(body)
          elseif name == "basicConstraints" then
            ext.basic_constraints = parse_basic_constraints(body)
          elseif name == "keyUsage" then
            ext.key_usage = parse_key_usage(body)
          elseif critical and not M.OID[oid] then
            -- A critical extension a client does not understand means the
            -- certificate must be rejected (RFC 5280 4.2). Recording it
            -- here lets the caller decide rather than silently ignoring.
            critical_unknown[#critical_unknown + 1] = oid
          end
        end
      end
    end
  end

  return {
    version = version,
    serial = der.integer(serial),
    signature_algorithm = sigalg,
    signature = sig,
    -- The bytes the signature covers, exactly as they arrived.
    tbs_raw = tbs.raw,
    issuer = parse_name(issuer),
    subject = parse_name(subject),
    not_before = not_before,
    not_after = not_after,
    key = { algorithm = keyalg, curve = curve, bits = keybits,
            spki_raw = spki.raw },
    ext = ext,
    critical_unknown = critical_unknown,
    -- TBSCertificate repeats the signature algorithm; RFC 5280 4.1.1.2
    -- requires the two to agree, and a mismatch is a sign of an attempt
    -- to have the two ends read different things.
    algorithm_matches = (algorithm(inner_alg) or {}).oid == sigalg.oid,
  }
end

-- Hostname matching, RFC 6125: exact, or one leading wildcard label that
-- matches exactly one label and never the first label of a name with
-- fewer than three.
function M.matches_host(cert, host)
  host = host:lower():gsub("%.$", "")
  local names = cert.ext.san and cert.ext.san.dns or {}

  for _, n in ipairs(names) do
    n = n:lower()
    if n == host then return true end
    local rest = n:match "^%*%.(.+)$"
    if rest then
      local label, tail = host:match "^([^.]+)%.(.+)$"
      if label and tail == rest and select(2, rest:gsub("%.", "")) >= 1 then
        return true
      end
    end
  end
  return false
end

function M.valid_at(cert, when)
  return when >= cert.not_before.sortable and when <= cert.not_after.sortable
end

return M
