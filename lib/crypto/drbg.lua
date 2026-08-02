-- A ChaCha20 DRBG, seeded once and expanded in Lua.
--
-- The C surface for entropy is one function: los.platform.rng's
-- rng.bytes, which exists in the boot proc alone because the raw
-- function IS the capability -- there is no handle to check. Everything
-- else is handed a SEED, as ordinary data in its spawn arg, and expands
-- it here. So a proc that needs randomness needs no new authority, and
-- the thing that must not be got wrong stays in one place.
--
-- Fast key erasure (Bernstein): each draw generates 32 bytes of new key
-- plus the bytes asked for, and the new key replaces the old
-- immediately. A state compromise therefore reveals nothing about
-- earlier output, which matters here because a long-lived sshd holds
-- this for the life of the machine and every session key comes out of
-- it.
--
-- Deliberately not offered: a way to run without a seed. There is no
-- honest fallback -- a predictable draw is not a degraded service but a
-- silently broken one -- so new() raises rather than inventing entropy
-- from the clock.

local chacha20 = require "crypto.chacha20"

local M = {}

local ZERO_NONCE = ("\0"):rep(12)

-- How much to ask of one ChaCha20 call. Any size works; this keeps a
-- single draw of a session key or an ephemeral scalar to one call.
local CHUNK = 992

function M.new(seed)
  if type(seed) ~= "string" or #seed < 32 then
    error("drbg: need at least 32 bytes of seed", 2)
  end

  -- More than 32 bytes of seed is folded in rather than truncated, so a
  -- caller who has extra entropy is not quietly ignored.
  local key = seed:sub(1, 32)
  if #seed > 32 then
    local sha256 = require "crypto.sha256"
    key = sha256.hash(seed)
  end

  local self = {}

  function self.bytes(n)
    if n == 0 then return "" end
    if n < 0 then error("drbg: negative length", 2) end

    local out, got = {}, 0

    while got < n do
      local want = n - got
      if want > CHUNK then want = CHUNK end

      -- One call yields the next key and the output together; the
      -- keystream is never reused because the key never is.
      local block = chacha20.xor(key, 0, ZERO_NONCE,
                                 ("\0"):rep(32 + want))
      key = block:sub(1, 32)
      out[#out + 1] = block:sub(33)
      got = got + want
    end

    return table.concat(out)
  end

  return self
end

return M
