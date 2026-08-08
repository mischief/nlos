-- HMAC, RFC 2104, over any hash module that crypto.hashstate defines.
--
-- Written for HKDF (crypto.hkdf) and therefore for the TLS 1.3 and
-- QUIC key schedules, which is the only caller so far: SSH itself never
-- needs a MAC, since chacha20-poly1305@openssh.com authenticates with
-- Poly1305 and the exchange hash is a bare hash.
--
-- Generic over the hash rather than fixed to SHA-256 because the key
-- schedule names its hash per cipher suite, and because a second hash is
-- what proves the block_len handling is not accidentally SHA-256's 64.
-- SHA-512's 128-byte block exercises the other side of that.

local M = {}

local srep, sbyte, schar, sconcat = string.rep, string.byte, string.char,
                                    table.concat

-- A key longer than a block is replaced by its own digest; a shorter one
-- is zero-padded. Both to block_len, which is the hash's block size and
-- not its digest size -- the one substitution that silently produces a
-- MAC that is wrong but self-consistent, so it verifies against itself
-- and against nothing else.
local function padkey(hash, key)
  if #key > hash.block_len then key = hash.hash(key) end
  return key .. srep("\0", hash.block_len - #key)
end

local function xorpad(k, b)
  local out = {}
  for i = 1, #k do out[i] = schar(sbyte(k, i) ~ b) end
  return sconcat(out)
end

local H = {}
H.__index = H

function H:update(s)
  self.inner:update(s)
  return self
end

function H:final()
  return self.hash.hash(self.opad .. self.inner:final())
end

-- new(hash, key) -> state with :update / :final, as in hashstate.
function M.new(hash, key)
  local k = padkey(hash, key)
  local self = setmetatable({
    hash = hash,
    opad = xorpad(k, 0x5c),
  }, H)
  self.inner = hash.new()
  self.inner:update(xorpad(k, 0x36))
  return self
end

-- One-shot.
function M.auth(hash, key, msg)
  return M.new(hash, key):update(msg):final()
end

return M
