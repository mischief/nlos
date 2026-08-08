-- TLS's wire types: length-prefixed vectors and the extension list.
--
-- RFC 8446 3.4: every variable-length field carries its length in a
-- fixed number of bytes, and the length is of the *contents*. The three
-- widths that appear are one, two and three bytes; the three-byte one
-- exists only for handshake messages and certificates.
--
-- Reading returns the value and the offset after it, as quic.varint
-- does, so a caller walks a buffer with no cursor object. A short buffer
-- returns nil rather than raising: a ClientHello off the network is
-- attacker-controlled, and every truncation is an ordinary event.

local M = {}

local spack, sunpack = string.pack, string.unpack

local INT = { [1] = ">I1", [2] = ">I2", [3] = ">I3", [4] = ">I4" }

function M.int(s, off, n)
  if #s < off + n - 1 then return nil end
  return sunpack(INT[n], s, off), off + n
end

-- A vector: `n` bytes of length, then that many bytes.
function M.vec(s, off, n)
  local len
  len, off = M.int(s, off, n)
  if not len or #s < off + len - 1 then return nil end
  return s:sub(off, off + len - 1), off + len
end

function M.wint(v, n)
  return spack(INT[n], v)
end

function M.wvec(s, n)
  return spack(INT[n], #s) .. s
end

-- The extension list: a two-byte vector of { type, two-byte vector }.
-- Returned as a map from type to body, plus the order, which matters for
-- reproducing a transcript byte for byte but not for reading one.
function M.extensions(s)
  local out, order, off = {}, {}, 1
  while off <= #s do
    local t, body
    t, off = M.int(s, off, 2)
    if not t then return nil, "truncated extension type" end
    body, off = M.vec(s, off, 2)
    if not body then return nil, "truncated extension body" end
    out[t] = body
    order[#order + 1] = t
  end
  return out, order
end

function M.wextensions(list)
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = M.wint(e.type, 2) .. M.wvec(e.body, 2)
  end
  return M.wvec(table.concat(out), 2)
end

-- A handshake message: one-byte type, three-byte length, body.
function M.handshake(t, body)
  return M.wint(t, 1) .. M.wvec(body, 3)
end

function M.read_handshake(s, off)
  off = off or 1
  local t, len, body
  t, off = M.int(s, off, 1)
  if not t then return nil end
  len = select(1, M.int(s, off, 3))
  if not len then return nil end
  body, off = M.vec(s, off, 3)
  if not body then return nil, "incomplete" end
  return { type = t, body = body }, off
end

return M
