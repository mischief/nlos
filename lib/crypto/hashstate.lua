-- The streaming half of a Merkle-Damgard hash, shared by SHA-256 and
-- SHA-512.
--
-- Both hashes differ only in word size, block size, constants and the
-- width of the length field. Buffering partial writes and building the
-- padding is identical between them and is the part with the off-by-one
-- in it, so it lives here once.
--
-- The interface is Go's hash.Hash, spelled in Lua:
--
--   local s = sha256.new()
--   s:update(bytes)          -- Write; returns self, so it chains
--   s:final()                -- Sum; does not disturb the state
--   s:reset()                -- Reset
--   sha256.digest_len        -- Size
--   sha256.block_len         -- BlockSize
--
-- `final` snapshotting rather than consuming is what Go's Sum does, and
-- SSH wants it: the exchange hash is summed and then the same running
-- state would be inconvenient to rebuild. Nothing here relies on it, but
-- a caller that does will not be surprised.

local M = {}

local srep, sconcat = string.rep, table.concat

function M.define(spec)
  local block_len = spec.block_len
  local len_bytes = spec.len_bytes
  local compress = spec.compress
  local encode = spec.encode

  local H = {}
  H.__index = H

  local mod = {
    block_len = block_len,
    digest_len = spec.digest_len,
    -- Retained under the old names too: SSH's own naming is SHOUTY and
    -- several callers were written against these first.
    DIGEST_LEN = spec.digest_len,
    BLOCK_LEN = block_len,
  }

  function H:reset()
    self.h = spec.initial()
    self.pend, self.npend, self.len = {}, 0, 0
    return self
  end

  function H:update(s)
    if #s == 0 then return self end

    self.len = self.len + #s
    self.npend = self.npend + #s
    self.pend[#self.pend + 1] = s

    if self.npend < block_len then return self end

    local buf = sconcat(self.pend)
    local n = #buf
    local full = n - (n % block_len)
    for off = 1, full, block_len do compress(self.h, buf, off) end

    if full == n then
      self.pend, self.npend = {}, 0
    else
      self.pend, self.npend = { buf:sub(full + 1) }, n - full
    end

    return self
  end

  -- The padding: 0x80, zeros, then the bit length in the top len_bytes of
  -- a block. If the tail plus the marker will not leave room for the
  -- length, it spills into one more block, which is what the modulo
  -- arithmetic below expresses.
  function H:final()
    local h = {}
    for i = 1, #self.h do h[i] = self.h[i] end

    local tail = sconcat(self.pend)
    local zeros = (block_len - len_bytes - 1 - #tail) % block_len
    local s = tail .. "\128" .. srep("\0", zeros)
             .. srep("\0", len_bytes - 8) .. spec.enclen(self.len * 8)

    for off = 1, #s, block_len do compress(h, s, off) end

    return encode(h)
  end

  function mod.new()
    return setmetatable({}, H):reset()
  end

  function mod.hash(s)
    return mod.new():update(s):final()
  end

  return mod
end

return M
