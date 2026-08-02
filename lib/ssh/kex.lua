-- Key exchange: curve25519-sha256 with an ssh-ed25519 host key.
--
-- One algorithm in every slot and no fallback anywhere, so "negotiation"
-- is: send our list, check the server offered what we require, disconnect
-- otherwise. There is no matrix and no downgrade to reason about.
--
-- The MAC list is deliberately empty. chacha20-poly1305@openssh.com is an
-- AEAD and carries its own authentication, so there is no separate MAC
-- algorithm anywhere in this implementation.

local wire = require "ssh.wire"
local msg = require "ssh.msg"
local sha256 = require "crypto.sha256"
local x25519 = require "crypto.x25519"
local ed25519 = require "crypto.ed25519"

local M = {}

M.KEX = "curve25519-sha256"
M.KEX_ALIAS = "curve25519-sha256@libssh.org"
M.HOSTKEY = "ssh-ed25519"
M.CIPHER = "chacha20-poly1305@openssh.com"

-- The Terrapin countermeasure. Both ends here require it of the other:
-- having no legacy to support is exactly what makes refusing affordable.
M.STRICT_C = "kex-strict-c-v00@openssh.com"
M.STRICT_S = "kex-strict-s-v00@openssh.com"

local function has(list, want)
  for _, v in ipairs(list) do if v == want then return true end end
  return false
end

-- Our KEXINIT payload. Returned whole because it goes into the exchange
-- hash verbatim, byte for byte as sent.
function M.kexinit(rand, role)
  local w = wire.writer()
  w:byte(msg.KEXINIT)
  w:raw(rand(16))
  w:namelist { M.KEX, M.KEX_ALIAS,
               role == "server" and M.STRICT_S or M.STRICT_C }
  w:namelist { M.HOSTKEY }
  w:namelist { M.CIPHER }               -- client to server
  w:namelist { M.CIPHER }               -- server to client
  w:namelist {}                         -- mac c2s: none, the cipher is AEAD
  w:namelist {}                         -- mac s2c
  w:namelist { "none" }                 -- compression c2s
  w:namelist { "none" }                 -- compression s2c
  w:namelist {}                         -- languages c2s
  w:namelist {}                         -- languages s2c
  w:boolean(false)                      -- first_kex_packet_follows
  w:uint32(0)                           -- reserved
  return w:tostring()
end

-- Check the peer's KEXINIT offers everything we require, and report
-- whether it asked for strict kex. `role` is ours, so the strict flag we
-- look for is the other one.
function M.check(payload, role)
  local r = wire.reader(payload)
  if r:byte() ~= msg.KEXINIT then return nil, "not a KEXINIT" end
  if not r:raw(16) then return nil, "truncated KEXINIT" end

  local kexes = r:namelist()
  local hostkeys = r:namelist()
  local enc_c2s = r:namelist()
  local enc_s2c = r:namelist()
  if not (kexes and hostkeys and enc_c2s and enc_s2c) then
    return nil, "truncated KEXINIT"
  end

  if not (has(kexes, M.KEX) or has(kexes, M.KEX_ALIAS)) then
    return nil, "peer does not offer " .. M.KEX
  end
  if not has(hostkeys, M.HOSTKEY) then
    return nil, "peer does not accept a " .. M.HOSTKEY .. " host key"
  end
  if not (has(enc_c2s, M.CIPHER) and has(enc_s2c, M.CIPHER)) then
    return nil, "peer does not offer " .. M.CIPHER
  end

  return { strict = has(kexes, role == "server" and M.STRICT_C or M.STRICT_S) }
end

-- H = HASH(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K), RFC 5656
-- section 4 as narrowed by RFC 8731. Every element is a string except K,
-- which is an mpint.
local function exchange_hash(t)
  local w = wire.writer()
  w:string(t.v_c)
  w:string(t.v_s)
  w:string(t.i_c)
  w:string(t.i_s)
  w:string(t.k_s)
  w:string(t.q_c)
  w:string(t.q_s)
  w:mpint(t.k)
  return sha256.hash(w:tostring())
end
M.exchange_hash = exchange_hash

-- Split an ssh-ed25519 blob into its algorithm name and 32-byte key.
function M.parse_hostkey(blob)
  local r = wire.reader(blob)
  local alg = r:string()
  local key = r:string()
  if alg ~= M.HOSTKEY then return nil, "host key is not " .. M.HOSTKEY end
  if not key or #key ~= 32 then return nil, "malformed ed25519 host key" end
  return key
end

function M.parse_signature(blob)
  local r = wire.reader(blob)
  local alg = r:string()
  local sig = r:string()
  if alg ~= M.HOSTKEY then return nil, "signature is not " .. M.HOSTKEY end
  if not sig or #sig ~= 64 then return nil, "malformed ed25519 signature" end
  return sig
end

-- Derive one key stream of `want` bytes, RFC 4253 section 7.2:
--   K1 = HASH(K || H || X || session_id); K2 = HASH(K || H || K1); ...
local function derive(k_mpint, h, letter, session_id, want)
  local out = sha256.hash(k_mpint .. h .. letter .. session_id)
  while #out < want do
    out = out .. sha256.hash(k_mpint .. h .. out)
  end
  return out:sub(1, want)
end

-- The full client half of the exchange. `io` supplies sendpkt/recvpkt;
-- `verify_host` is called with the 32-byte host key and must return true.
function M.client(t)
  local sendpkt, recvpkt, rand = t.sendpkt, t.recvpkt, t.rand

  local priv = rand(32)
  local q_c = x25519.scalarmult_base(priv)

  local w = wire.writer()
  w:byte(msg.KEX_ECDH_INIT):string(q_c)
  local ok, err = sendpkt(w:tostring())
  if not ok then return nil, err end

  local payload
  payload, err = recvpkt()
  if not payload then return nil, err end
  if payload:byte(1) ~= msg.KEX_ECDH_REPLY then
    return nil, ("expected KEX_ECDH_REPLY, got %s")
      :format(msg.name[payload:byte(1)] or payload:byte(1))
  end

  local r = wire.reader(payload)
  r:byte()
  local k_s = r:string()
  local q_s = r:string()
  local sigblob = r:string()
  if not (k_s and q_s and sigblob) then return nil, "truncated KEX_ECDH_REPLY" end
  if #q_s ~= 32 then return nil, "bad server ephemeral key" end

  local hostkey
  hostkey, err = M.parse_hostkey(k_s)
  if not hostkey then return nil, err end

  local sig
  sig, err = M.parse_signature(sigblob)
  if not sig then return nil, err end

  local k
  k, err = x25519.shared(priv, q_s)
  if not k then return nil, err end

  local h = exchange_hash {
    v_c = t.v_c, v_s = t.v_s, i_c = t.i_c, i_s = t.i_s,
    k_s = k_s, q_c = q_c, q_s = q_s, k = k,
  }

  -- Verify the signature BEFORE trusting the host key, then decide
  -- whether that host key is one we accept. Both, in that order.
  if not ed25519.verify(hostkey, h, sig) then
    return nil, "host key signature does not verify"
  end
  ok, err = t.verify_host(hostkey, h)
  if not ok then return nil, err or "host key rejected" end

  local session_id = t.session_id or h
  local kmp = wire.writer():mpint(k):tostring()

  return {
    h = h,
    session_id = session_id,
    hostkey = hostkey,
    -- 'A'..'F' per RFC 4253 7.2. The IV letters are unused: this cipher
    -- derives its nonce from the sequence number.
    keys = {
      c2s = derive(kmp, h, "C", session_id, 64),
      s2c = derive(kmp, h, "D", session_id, 64),
    },
  }
end

-- The server half. Mirrors M.client: same exchange hash over the same
-- eight fields, but this end holds the host key and signs H rather than
-- checking the signature over it.
--
-- The key schedule is identical and deliberately not flipped here. 'C' is
-- always client-to-server and 'D' always server-to-client; which of them
-- is "outgoing" is the caller's business, which is why setkeys takes a
-- direction rather than a role.
function M.server(t)
  local sendpkt, recvpkt, rand = t.sendpkt, t.recvpkt, t.rand

  local payload, err = recvpkt()
  if not payload then return nil, err end
  if payload:byte(1) ~= msg.KEX_ECDH_INIT then
    return nil, ("expected KEX_ECDH_INIT, got %s")
      :format(msg.name[payload:byte(1)] or payload:byte(1))
  end

  local r = wire.reader(payload)
  r:byte()
  local q_c = r:string()
  if not q_c or #q_c ~= 32 then return nil, "bad client ephemeral key" end

  local priv = rand(32)
  local q_s = x25519.scalarmult_base(priv)

  local k
  k, err = x25519.shared(priv, q_c)
  if not k then return nil, err end

  local k_s = wire.writer():string(M.HOSTKEY):string(t.hostkey_pub):tostring()

  local h = exchange_hash {
    v_c = t.v_c, v_s = t.v_s, i_c = t.i_c, i_s = t.i_s,
    k_s = k_s, q_c = q_c, q_s = q_s, k = k,
  }

  local sigblob = wire.writer()
    :string(M.HOSTKEY)
    :string(ed25519.sign(t.hostkey_seed, h))
    :tostring()

  local w = wire.writer()
  w:byte(msg.KEX_ECDH_REPLY):string(k_s):string(q_s):string(sigblob)
  local ok
  ok, err = sendpkt(w:tostring())
  if not ok then return nil, err end

  local session_id = t.session_id or h
  local kmp = wire.writer():mpint(k):tostring()

  return {
    h = h,
    session_id = session_id,
    keys = {
      c2s = derive(kmp, h, "C", session_id, 64),
      s2c = derive(kmp, h, "D", session_id, 64),
    },
  }
end

return M
