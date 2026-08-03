-- Host-side gefs test helper: what spec/helper.lua is in the standalone
-- gefs tree, reworked for lua-os. No busted and no luaposix -- the device
-- is gefs.ram in memory or gefs.io over a real file, and the crash device
-- below yields through a coroutine instead of raising.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local gefs = require "gefs"

local M = {}

M.gefs = gefs
M.dat = gefs.dat
M.pack = gefs.pack

-- a volume in memory, reamed and mounted. Tests that want a deep tree
-- ask for a small block size rather than a big disk.
function M.volume(opts)
  opts = opts or {}
  local size = opts.size or 128 * 1024 * 1024
  local blksz = opts.blksz or 16384
  local dev = opts.dev or gefs.ram.new(size, blksz)
  gefs.ream(dev, { user = opts.user or "glenda", blksz = blksz })
  local fs = gefs.open(dev, opts)
  return fs, dev
end

function M.mounted(opts)
  local fs, dev = M.volume(opts)
  return fs:mount("main"), fs, dev
end

-- assert the volume is sound, reporting what is wrong rather than just
-- that something is
function M.sound(fs, what)
  local fail = fs:check()
  if #fail ~= 0 then
    error(("%s: %d problems\n  %s")
      :format(what or "check", #fail, table.concat(fail, "\n  ")), 2)
  end
end

-- deterministic randomness, so a failing seed reproduces
function M.rng(seed)
  local s = seed
  return function(n)
    s = (s * 6364136223846793005 + 1442695040888963407) & 0xffffffffffffffff
    local v = (s >> 33) & 0x7fffffff
    if n == nil then return v end
    return v % n + 1
  end
end

function M.randstr(rand, n)
  local t = {}
  for i = 1, n do t[i] = string.char(32 + rand(95) - 1) end
  return table.concat(t)
end

--------------------------------------------------------------------------
-- a device that cuts the power mid-write, through a coroutine
--
-- gefs.ram.cut fails a whole write past the nth, which models a power
-- cut at block granularity. This goes finer: it splits each block write
-- into grain-sized chunks, flushing every chunk to the real file before
-- yielding, so the cut can land inside a single block and leave it torn
-- -- the case the per-block checksum exists to catch. And it yields
-- rather than raising, so the driver abandons the coroutine at a chosen
-- point instead of unwinding it: nothing runs afterwards, which is what
-- losing power actually is.
--
-- It only yields while armed, and the driver arms it immediately before
-- fs:sync(). That keeps every yield on the commit path, which is
-- straight-line Lua with no pcall between it and the device write --
-- yielding out of the read paths (some reached through pcall) would
-- cross a C-call boundary and error.

local Cocut = {}
Cocut.__index = Cocut

function M.cocut(dev, grain)
  return setmetatable({
    dev = dev, grain = grain or 512, armed = false, yields = 0,
  }, Cocut)
end

function Cocut:arm() self.armed = true end
function Cocut:size() return self.dev:size() end
function Cocut:read(off, len) return self.dev:read(off, len) end

function Cocut:write(off, s)
  if not self.armed then
    self.dev:write(off, s)
    return
  end
  local pos = 1
  while pos <= #s do
    local chunk = s:sub(pos, pos + self.grain - 1)
    self.dev:write(off + pos - 1, chunk)
    if self.dev.sync then self.dev:sync() end   -- the byte is on the platter
    pos = pos + #chunk
    self.yields = self.yields + 1
    coroutine.yield("wrote")
  end
end

function Cocut:sync()
  if self.dev.sync then self.dev:sync() end
  if self.armed then
    self.yields = self.yields + 1
    coroutine.yield("barrier")   -- a cut between commit passes
  end
end

-- run body(dev) inside a coroutine and abandon it after the kth yield
-- (the kth chunk or barrier reaches disk, nothing past it does). Returns
-- the number of yields seen and whether it was actually cut (false means
-- body finished on its own before k).
function M.crashafter(body, dev, k)
  dev.armed = false
  dev.yields = 0
  local co = coroutine.create(function() body(dev) end)
  local n = 0
  while true do
    local ok, ev = coroutine.resume(co)
    if not ok then error(ev, 0) end
    if coroutine.status(co) == "dead" then
      return n, false
    end
    n = n + 1
    if n >= k then
      return n, true   -- cut: co is dropped, unresumed
    end
  end
end

return M
