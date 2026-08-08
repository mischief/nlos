-- DER: the subset of ASN.1 that X.509 uses. X.690, distinguished
-- encoding rules.
--
-- Every value is tag, length, contents. The tag's low five bits are the
-- number when it is under 31, the length is either one byte under 128 or
-- a count of following length bytes, and DER -- unlike BER -- forbids
-- the indefinite form, so a parser never has to hunt for an end-of-
-- contents marker.
--
-- This is a reader and nothing else. Nothing in this tree writes a
-- certificate: a server sends a chain it was handed, and this exists for
-- a client, which only ever reads.
--
-- ---- what a certificate parser has to be careful about ----
--
-- It runs on attacker-supplied bytes before anything has been verified,
-- so every read is bounds-checked and returns nil rather than raising,
-- and lengths are checked against the buffer rather than trusted. The
-- one thing this deliberately does not do is accept sloppy encodings:
-- a non-minimal length, a negative length, or contents that overrun
-- their parent are all refused. A permissive parser and a strict one
-- disagreeing about where a field ends is how signatures end up covering
-- something other than what was read.

local M = {}

local sunpack = string.unpack

M.TAG = {
  boolean = 0x01,
  integer = 0x02,
  bitstring = 0x03,
  octetstring = 0x04,
  null = 0x05,
  oid = 0x06,
  utf8string = 0x0c,
  sequence = 0x30,
  set = 0x31,
  printablestring = 0x13,
  teletexstring = 0x14,
  ia5string = 0x16,
  utctime = 0x17,
  generalizedtime = 0x18,
}

-- read(s, off) -> { tag, contents, from, to }, next_off  |  nil, reason
--
-- `from` and `to` bracket the whole element, header included, because a
-- signature covers the encoding of a field and not its value: TBSCert
-- has to be handed to the verifier exactly as it appeared.
function M.read(s, off)
  off = off or 1
  local tag = s:byte(off)
  if not tag then return nil, "truncated tag" end
  if tag & 0x1f == 0x1f then return nil, "multi-byte tags not supported" end

  local first = s:byte(off + 1)
  if not first then return nil, "truncated length" end

  local len, hdr
  if first < 0x80 then
    len, hdr = first, 2
  else
    local n = first & 0x7f
    if n == 0 then return nil, "indefinite length is not DER" end
    if n > 4 then return nil, "length too large" end
    if #s < off + 1 + n then return nil, "truncated length" end
    len = 0
    for i = 1, n do len = (len << 8) | s:byte(off + 1 + i) end
    -- DER wants the shortest encoding; a padded one is a different
    -- encoding of the same certificate, and two of those is one too many.
    if len < 0x80 then return nil, "non-minimal length" end
    hdr = 2 + n
  end

  local from, to = off, off + hdr + len - 1
  if to > #s then return nil, "element overruns the buffer" end

  return {
    tag = tag,
    contents = s:sub(off + hdr, to),
    from = from,
    to = to,
    raw = s:sub(from, to),
  }, to + 1
end

-- Read expecting a particular tag.
function M.expect(s, off, tag)
  local e, next_off = M.read(s, off)
  if not e then return nil, next_off end
  if e.tag ~= tag then
    return nil, ("expected tag 0x%02x, got 0x%02x"):format(tag, e.tag)
  end
  return e, next_off
end

-- Walk the children of a constructed element.
function M.children(e)
  local out, off = {}, 1
  while off <= #e.contents do
    local child
    child, off = M.read(e.contents, off)
    if not child then return nil, off end
    out[#out + 1] = child
  end
  return out
end

-- An INTEGER, as a Lua number when it fits and as bytes when it does
-- not -- which is normal: serial numbers and RSA moduli are both
-- INTEGERs and only one of them is a number.
function M.integer(e)
  local s = e.contents
  if #s == 0 then return nil, "empty integer" end
  if #s <= 8 then
    local v = 0
    for i = 1, #s do v = (v << 8) | s:byte(i) end
    if s:byte(1) & 0x80 ~= 0 then v = v - (1 << (8 * #s)) end
    return v
  end
  -- Leading zero byte: DER adds one when the high bit would otherwise
  -- make the value negative, and a caller wanting the magnitude does not
  -- want it.
  return (s:byte(1) == 0) and s:sub(2) or s
end

-- An OBJECT IDENTIFIER, as its dotted form. The first byte encodes two
-- arcs at once and the rest is base-128 with a continuation bit.
function M.oid(e)
  local s = e.contents
  if #s == 0 then return nil, "empty oid" end

  local first = s:byte(1)
  local out = { tostring(first // 40), tostring(first % 40) }

  local v = 0
  for i = 2, #s do
    local b = s:byte(i)
    v = (v << 7) | (b & 0x7f)
    if b & 0x80 == 0 then
      out[#out + 1] = tostring(v)
      v = 0
    end
  end
  return table.concat(out, ".")
end

-- A BIT STRING, as bytes, refusing the unused-bit forms that a key or a
-- signature never has.
function M.bitstring(e)
  local s = e.contents
  if #s == 0 then return nil, "empty bit string" end
  local unused = s:byte(1)
  if unused ~= 0 then return nil, "bit string is not a whole number of bytes" end
  return s:sub(2)
end

-- UTCTime and GeneralizedTime, to a table and to a comparable number.
-- Two-digit years are 1950..2049 by RFC 5280 4.1.2.5.1, which is the
-- kind of rule that outlives the format it belongs to.
function M.time(e)
  local s = e.contents
  local year, rest

  if e.tag == M.TAG.utctime then
    local yy = tonumber(s:sub(1, 2))
    if not yy then return nil, "bad UTCTime" end
    year = yy >= 50 and 1900 + yy or 2000 + yy
    rest = s:sub(3)
  elseif e.tag == M.TAG.generalizedtime then
    year = tonumber(s:sub(1, 4))
    rest = s:sub(5)
  else
    return nil, "not a time"
  end

  local mo, d, h, mi = rest:match "^(%d%d)(%d%d)(%d%d)(%d%d)"
  if not mo then return nil, "bad time" end
  local sec = tonumber(rest:sub(9, 10)) or 0

  return {
    year = year, month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = sec,
    -- os.time would apply the local timezone; certificates are in UTC,
    -- and a comparable ordering is all any caller here needs.
    sortable = ("%04d%02d%02d%02d%02d%02d"):format(
      year, tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), sec),
  }
end

return M
