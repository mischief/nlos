-- nostr events, NIP-01: the id, the signature and the keys. No relay
-- connection -- that needs a websocket and a JSON parser, and nothing
-- below needs either. The id is SHA-256 over a JSON array in a fixed
-- order, written by hand here: an encoder may order a map or render a
-- number as it likes, and that is an event nobody can verify.

local sha256 = require "crypto.sha256"
local secp = require "crypto.secp256k1"
local bech32 = require "bech32"

local M = {}

local byte, char, concat, format = string.byte, string.char, table.concat,
                                  string.format

function M.hex(s)
  return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
end

function M.unhex(s)
  if type(s) ~= "string" or #s % 2 ~= 0 or s:find "[^0-9a-fA-F]" then
    return nil
  end
  return (s:gsub("..", function(b) return char(tonumber(b, 16)) end))
end

local hex, unhex = M.hex, M.unhex

--------------------------------------------------------------------------
-- the canonical form

-- NIP-01 names the escapes exactly: backslash, quote, and four named
-- controls. Everything else below 0x20 is \u00xx, and nothing above is
-- escaped at all.
local ESC = {
  ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r",
  ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local function jstr(s)
  return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
    return ESC[c] or format("\\u%04x", byte(c))
  end) .. '"'
end

local function jtags(tags)
  local out = {}
  for i, tag in ipairs(tags or {}) do
    local one = {}
    for j, v in ipairs(tag) do one[j] = jstr(v) end
    out[i] = "[" .. concat(one, ",") .. "]"
  end
  return "[" .. concat(out, ",") .. "]"
end

-- serialize(ev) -> the exact bytes the id hashes.
function M.serialize(ev)
  return concat {
    "[0,", jstr(ev.pubkey), ",",
    format("%d", ev.created_at), ",",
    format("%d", ev.kind), ",",
    jtags(ev.tags), ",", jstr(ev.content), "]",
  }
end

function M.id(ev)
  return sha256.hash(M.serialize(ev))
end

--------------------------------------------------------------------------
-- keys

-- genkey(rand) -> 32 bytes, or nil and why.
--
-- rand is the caller's entropy, as everywhere else here. A draw outside
-- the curve's order is redrawn rather than reduced: reducing would bias
-- the low end, and the odds of one draw landing there are near enough to
-- nothing that the loop almost never turns twice.
function M.genkey(rand)
  if type(rand) ~= "function" then return nil, "no entropy" end
  for _ = 1, 8 do
    local sec = rand(32)
    if type(sec) == "string" and #sec == 32 and secp.pubkey(sec) then
      return sec
    end
  end
  return nil, "no usable key in eight draws"
end

-- seckey(s) -> 32 bytes, from an nsec or from hex.
function M.seckey(s)
  s = tostring(s or ""):gsub("%s+", "")
  if s:sub(1, 4) == "nsec" then
    local hrp, raw = bech32.decode_bytes(s, { limit = false })
    if hrp ~= "nsec" or not raw or #raw ~= 32 then
      return nil, "not an nsec"
    end
    return raw
  end

  local raw = unhex(s)
  if not raw or #raw ~= 32 then return nil, "not a 32 byte key" end
  return raw
end

-- NIP-19 has no length limit, which is why bech32 takes one.
function M.npub(pub)
  return bech32.encode_bytes("npub", pub, { limit = false })
end

function M.nsec(sec)
  return bech32.encode_bytes("nsec", sec, { limit = false })
end

function M.pubkey(sec)
  return secp.pubkey(sec)
end

--------------------------------------------------------------------------
-- events

-- sign(sec, kind, content, tags, now) -> an event, or nil and why.
--
-- `now` is an argument rather than a clock read here: created_at is the
-- one field a relay judges an event by, and a machine that has just
-- booted may believe anything.
function M.sign(sec, kind, content, tags, now, aux)
  local pub, err = secp.pubkey(sec)
  if not pub then return nil, err or "bad secret key" end

  local ev = {
    pubkey = hex(pub),
    created_at = math.tointeger(now) or 0,
    kind = kind,
    tags = tags or {},
    content = content or "",
  }

  local raw = M.id(ev)
  local sig, serr = secp.sign(sec, raw, aux)
  if not sig then return nil, serr or "signing failed" end

  ev.id, ev.sig = hex(raw), hex(sig)
  return ev
end

-- verify(ev) -> true, or false and why. The id is checked first:
-- rehashing is cheap, and a mismatch means the content moved under a
-- signature that is otherwise good.
function M.verify(ev)
  if type(ev) ~= "table" or type(ev.id) ~= "string" or
     type(ev.sig) ~= "string" or type(ev.pubkey) ~= "string" then
    return false, "not an event"
  end

  local want, pub, sig = unhex(ev.id), unhex(ev.pubkey), unhex(ev.sig)
  if not want or #want ~= 32 then return false, "bad id" end
  if not pub or #pub ~= 32 then return false, "bad pubkey" end
  if not sig or #sig ~= 64 then return false, "bad signature" end

  local ok, got = pcall(M.id, ev)
  if not ok then return false, "cannot serialize" end
  if got ~= want then return false, "id does not match the event" end
  if secp.verify(pub, want, sig) ~= true then
    return false, "signature does not verify"
  end
  return true
end

return M
