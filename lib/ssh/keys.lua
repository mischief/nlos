-- ssh-ed25519 keys: the blob encoding, the fingerprint, and reading a
-- public line or a private file.
--
-- Text in, keys out, and no io: the host-side version of this module
-- opens the paths itself, where a proc has no io.open and reads through
-- its namespace instead. So the caller brings the bytes.

local wire = require "ssh.wire"
local base64 = require "ssh.base64"
local sha256 = require "crypto.sha256"

local M = {}

local MAGIC = "openssh-key-v1\0"

-- The ssh-ed25519 public key blob: string "ssh-ed25519", string pk.
function M.blob(pk)
  return wire.writer():string("ssh-ed25519"):string(pk):tostring()
end

-- OpenSSH's fingerprint: SHA256 of the blob, base64, unpadded.
function M.fingerprint(blob)
  return "SHA256:" .. base64.encode(sha256.hash(blob), false)
end

-- Parse an authorized_keys / .pub line: "ssh-ed25519 <base64> comment".
function M.parse_public(line)
  local alg, b64 = line:match "^%s*(%S+)%s+(%S+)"
  if not alg then return nil, "not a public key line" end
  if alg ~= "ssh-ed25519" then return nil, "unsupported key type " .. alg end

  local blob = base64.decode(b64)
  if not blob then return nil, "bad base64" end

  local r = wire.reader(blob)
  if r:string() ~= "ssh-ed25519" then return nil, "blob type mismatch" end
  local pk = r:string()
  if not pk or #pk ~= 32 then return nil, "bad ed25519 key length" end

  return pk, blob
end

-- Parse a PEM-armoured openssh-key-v1 private key. Returns the 32-byte
-- seed and the 32-byte public key.
--
-- Unencrypted only: decrypting one wants bcrypt_pbkdf and AES-CTR, two
-- primitives nothing else here needs. An encrypted key is an error that
-- says so rather than a silent failure.
function M.parse_private(text)
  local b64 = text:match
    "%-%-%-%-%-BEGIN OPENSSH PRIVATE KEY%-%-%-%-%-(.-)%-%-%-%-%-END"
  if not b64 then return nil, "not an openssh private key" end

  local raw = base64.decode(b64)
  if not raw then return nil, "bad base64" end
  if raw:sub(1, #MAGIC) ~= MAGIC then return nil, "bad magic" end

  local r = wire.reader(raw)
  r:raw(#MAGIC)

  local ciphername = r:string()
  local kdfname = r:string()
  r:string()                                  -- kdf options
  local nkeys = r:uint32()
  if not nkeys or nkeys < 1 then return nil, "no keys in file" end

  if ciphername ~= "none" or kdfname ~= "none" then
    return nil, ("key is encrypted with %s; decrypt it first " ..
                 "(ssh-keygen -p)"):format(ciphername)
  end

  r:string()                                  -- public key blob
  local priv = r:string()
  if not priv then return nil, "truncated private section" end

  local p = wire.reader(priv)
  local c1, c2 = p:uint32(), p:uint32()
  if not c1 or c1 ~= c2 then
    return nil, "private key checkint mismatch (wrong passphrase?)"
  end

  local keytype = p:string()
  if keytype ~= "ssh-ed25519" then
    return nil, "unsupported key type " .. tostring(keytype)
  end

  local pk = p:string()
  local sk = p:string()
  if not pk or #pk ~= 32 then return nil, "bad public key length" end
  if not sk or #sk ~= 64 then return nil, "bad private key length" end

  -- OpenSSH stores seed||public. Deriving the public key from the seed
  -- and checking it agrees catches a corrupt file, and is a live test
  -- that our Ed25519 and OpenSSH's agree about this key.
  local ed25519 = require "crypto.ed25519"
  local seed = sk:sub(1, 32)

  if ed25519.publickey(seed) ~= pk then
    return nil, "private key does not match its public key"
  end

  return seed, pk
end

-- Look a host key up in known_hosts text. "ok", "unknown" or "changed",
-- which is the distinction a caller acts on.
--
-- A hashed entry (|1|salt|hash) is HMAC-SHA1 and reads as unknown: SHA-1
-- exists here for no other reason and is not worth adding.
function M.check_known_hosts(text, host, pk)
  local want = M.blob(pk)
  local seen_host = false

  for line in (text or ""):gmatch "[^\n]+" do
    if not line:match "^%s*#" and line:match "%S" then
      local hosts, alg, b64 = line:match "^%s*(%S+)%s+(%S+)%s+(%S+)"

      if hosts and alg == "ssh-ed25519" then
        for h in hosts:gmatch "[^,]+" do
          if h == host then
            seen_host = true
            if base64.decode(b64) == want then return "ok" end
          end
        end
      end
    end
  end

  return seen_host and "changed" or "unknown"
end

return M
