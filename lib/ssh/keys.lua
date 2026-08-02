-- ssh-ed25519 keys: the blob encoding, the fingerprint, and reading an
-- authorized_keys line.
--
-- The host-side version of this module also reads openssh-key-v1 private
-- keys and known_hosts. Neither is here, and not only because they are
-- unused: both want io.open, which a proc does not have, and a host key
-- on this machine is 32 bytes handed over in a spawn arg rather than a
-- file with a format.

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

return M
