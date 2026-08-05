-- A device in memory, and the two wrappers a test wants around one.
--
-- The device contract, which is all the filesystem knows about storage:
--
--      dev:read(off, len) -> string
--      dev:write(off, s)
--      dev:size()         -> bytes
--      dev:sync()         -- optional, called between commit passes
--
-- Offsets are bytes and always block-aligned. Nothing above this asks
-- for anything else, which is what lets the same code sit on a file, on
-- a 9P connection, or on a virtio queue.

local M = {}

--------------------------------------------------------------------------
-- a sparse disk
--
-- Blocks are held as strings in a table rather than one big buffer,
-- because a 1GiB volume in a test touches a few hundred blocks and Lua
-- has no cheap way to mutate the middle of a string.

local Ram = {}
Ram.__index = Ram

function M.new(size, blksz)
  return setmetatable({
    nbytes = size, blksz = blksz or 16384, blocks = {},
    nread = 0, nwrite = 0,
  }, Ram)
end

function Ram:size() return self.nbytes end

-- Resizing the backing store, which is what a volume has to see before
-- grow can use the space or shrink can give it back.
function Ram:resize(n)
  for bi in pairs(self.blocks) do
    if bi * self.blksz >= n then self.blocks[bi] = nil end
  end
  self.nbytes = n
end

function Ram:read(off, len)
  assert(off >= 0 and off + len <= self.nbytes, "read outside the device")
  self.nread = self.nread + 1
  local out = {}
  local pos = off
  local left = len
  while left > 0 do
    local bi = pos // self.blksz
    local bo = pos % self.blksz
    local n = self.blksz - bo
    if n > left then n = left end
    local b = self.blocks[bi]
    out[#out + 1] = b and b:sub(bo + 1, bo + n) or string.rep("\0", n)
    pos = pos + n
    left = left - n
  end
  return table.concat(out)
end

function Ram:write(off, s)
  assert(off >= 0 and off + #s <= self.nbytes, "write outside the device")
  assert(off % self.blksz == 0 and #s == self.blksz,
    "writes are whole blocks")
  self.nwrite = self.nwrite + 1
  self.blocks[off // self.blksz] = s
end

-- a copy that shares nothing, for taking a snapshot of a device mid-test
function Ram:clone()
  local n = M.new(self.nbytes, self.blksz)
  for k, v in pairs(self.blocks) do n.blocks[k] = v end
  return n
end

--------------------------------------------------------------------------
-- a device that stops
--
-- Wraps another device and fails every write past the nth. What is on
-- the disk afterwards is exactly what a power cut would have left,
-- assuming writes reach the platter in the order they were issued --
-- which is the assumption the commit passes are built on, so testing it
-- is testing the thing that matters.

local Cut = {}
Cut.__index = Cut

function M.cut(dev, after)
  return setmetatable({ dev = dev, left = after, cut = false }, Cut)
end

function Cut:size() return self.dev:size() end
function Cut:read(off, len) return self.dev:read(off, len) end

function Cut:write(off, s)
  if self.left <= 0 then
    self.cut = true
    error("device is gone", 0)
  end
  self.left = self.left - 1
  self.dev:write(off, s)
end

function Cut:sync() if self.dev.sync then self.dev:sync() end end

--------------------------------------------------------------------------
-- a device that reorders
--
-- Holds writes back and releases them out of order at sync(). A device
-- with no flush primitive behaves like this, which is the case the
-- virtio-blk driver this is aimed at actually presents: writes are
-- durable when the device says so and there is no way to ask.

local Lazy = {}
Lazy.__index = Lazy

function M.lazy(dev, rand)
  return setmetatable({
    dev = dev, pending = {}, rand = rand or math.random,
  }, Lazy)
end

function Lazy:size() return self.dev:size() end

function Lazy:read(off, len)
  -- a read sees this device's own pending writes, as a real one would
  for i = #self.pending, 1, -1 do
    local w = self.pending[i]
    if off >= w.off and off + len <= w.off + #w.s then
      return w.s:sub(off - w.off + 1, off - w.off + len)
    end
  end
  return self.dev:read(off, len)
end

function Lazy:write(off, s)
  self.pending[#self.pending + 1] = { off = off, s = s }
end

function Lazy:sync()
  local p = self.pending
  for i = #p, 2, -1 do
    local j = self.rand(i)
    p[i], p[j] = p[j], p[i]
  end
  for _, w in ipairs(p) do self.dev:write(w.off, w.s) end
  self.pending = {}
  if self.dev.sync then self.dev:sync() end
end

return M
