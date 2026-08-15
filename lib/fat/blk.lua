-- Sectors, and the cache between them and the device.
--
-- This is the only module that calls the device. Everything above it
-- addresses sectors by logical block number and never bytes, which is
-- what keeps the byte offset of a partition, or the fact that there is
-- a partition at all, out of the filesystem.
--
-- The cache is write-back: a dirty sector stays here until sync(). What
-- that buys is the FAT, whose one sector is touched on every allocation
-- and would otherwise be written once per cluster.

local Fs = require "fat.obj"

-- The methods go on the shared filesystem object; the module itself
-- holds nothing.
local buf = require("los.buf")

local M = {}

--------------------------------------------------------------------------
-- addressing

-- Byte offset of a sector on the device. The volume's own base is added
-- here, so a filesystem inside a partition needs nothing else.
function Fs:secoff(lba)
  return self.base + lba * self.secsz
end

function Fs:checklba(lba, n)
  if lba < 0 or lba + n > self.totsec then
    error(("sector %d outside the volume (%d sectors)")
      :format(lba, self.totsec), 0)
  end
end

--------------------------------------------------------------------------
-- the cache
--
-- Sectors are held as los.buf, so a change to part of one is bytes
-- written where they belong. Held as strings they could not be: every
-- write rebuilt the whole sector around the part that changed, which
-- for a 32-byte directory entry in a 4096-byte sector was three
-- allocations and 8KB copied.
--
-- A device that hands over the bytes it read -- a mount whose server
-- gives its buffer away -- costs nothing on the way in: what arrives is
-- the cached sector. One that answers with a string is copied once. The
-- way out is still a string.
--
-- A dirty one is remembered in insertion
-- order, so a flush writes in roughly the order the work happened,
-- which is the order a device handles best and the order a crash makes
-- the least surprising.

function Fs:cacheinit(limit)
  self.cache = {}
  self.dirty = {}
  self.ndirty = 0
  self.nclean = 0
  -- 128 sectors, which is 512KB of a 4096-byte one and the largest
  -- thing a fat server holds. Larger buys nothing measurable:
  -- streaming a file never revisits a sector, and the ones that are
  -- revisited -- the FAT, a directory -- are far fewer than this. Set
  -- `cache` to trade the other way.
  self.limit = limit or 128
  self.nread = 0
  self.nwrite = 0
end

-- Drop clean sectors only: a dirty one is the only copy of what it
-- holds until the next flush, so evicting it would lose a write. The
-- count is of clean sectors alone, which is what makes this cheap --
-- counting all of them would send a run of writes scanning the whole
-- cache for something evictable and finding nothing.
local function evict(fs)
  if fs.nclean <= fs.limit then return end
  for lba in pairs(fs.cache) do
    if not fs.dirty[lba] then
      fs.cache[lba] = nil
      fs.nclean = fs.nclean - 1
      if fs.nclean <= fs.limit // 2 then break end
    end
  end
end

function Fs:rdsec(lba)
  local s = self.cache[lba]
  if s then return s end
  self:checklba(lba, 1)
  local r, err
  if self.dev.readbuf then
    r, err = self.dev:readbuf(self:secoff(lba), self.secsz)
  else
    r, err = self.dev:read(self:secoff(lba), self.secsz)
  end
  if not r then error("read failed: " .. tostring(err), 0) end
  if #r ~= self.secsz then error("short read at sector " .. lba, 0) end
  self.nread = self.nread + 1
  -- a buffer the device gave away is the cached sector: it is ours,
  -- writable, and the right size. Anything else is copied into one.
  local sec = r
  if not buf.is(sec) or not sec:movable() then
    sec = buf.new(self.secsz)
    sec:copy(1, r)
  end
  self.cache[lba] = sec
  r = sec
  self.nclean = self.nclean + 1
  evict(self)
  return r
end

-- s is a string or a buffer; either way the cache holds a buffer, so
-- what is cached is always writable in place.
function Fs:wrsec(lba, s)
  assert(#s == self.secsz, "a write is one whole sector")
  self:checklba(lba, 1)
  local was = self.cache[lba]
  local sec = was

  if sec == nil then
    sec = buf.new(self.secsz)
    self.cache[lba] = sec
  end
  if sec ~= s then sec:copy(1, s) end
  if not self.dirty[lba] then
    if was ~= nil then self.nclean = self.nclean - 1 end
    self.ndirty = self.ndirty + 1
    self.dirty[lba] = self.ndirty
  end
  -- Dirty sectors cannot be evicted, so a long run of writes would hold
  -- the whole run in memory. Writing them out at the same limit keeps
  -- the cache bounded; it is not a sync, and says nothing about
  -- durability, which is still what sync() is for.
  if self.ndirty >= self.limit then self:flush() end
end

-- A run of sectors as one string, and a run written back from one.
-- Reading a cluster is the common case and it is contiguous.
-- A run of sectors in one device read.
--
-- The cache is read but not filled: streaming never revisits a sector,
-- and filling would evict the FAT and directory sectors that are. A
-- dirty sector is the only copy of what it holds, so a run touching one
-- takes the per-sector path instead.
function Fs:rdrun(lba, n)
  if n <= 0 then
    return buf.new(0)
  end
  self:checklba(lba, n)
  -- only a dirty sector can differ from the device, and where none are
  -- held the scan is skipped entirely -- which is every read of a volume
  -- nothing has written.
  if self.ndirty > 0 then
    for i = lba, lba + n - 1 do
      if self.dirty[i] then
        return self:rdsecs(lba, n)
      end
    end
  end

  local want = n * self.secsz
  local r, err

  if self.dev.readbuf then
    r, err = self.dev:readbuf(self:secoff(lba), want)
  else
    r, err = self.dev:read(self:secoff(lba), want)
  end
  if not r then
    error("read failed: " .. tostring(err), 0)
  end
  if #r ~= want then
    error("short read at sector " .. lba, 0)
  end
  -- one read as far as this is concerned; what the device does with a
  -- run larger than one transfer is its own business.
  self.nread = self.nread + 1
  return r
end

-- One buffer for the run, each sector copied into it once. As strings
-- this was n slices and a concatenation of the whole cluster.
function Fs:rdsecs(lba, n)
  local out = buf.new(n * self.secsz)
  for i = 0, n - 1 do
    out:copy(i * self.secsz + 1, self:rdsec(lba + i))
  end
  return out
end

function Fs:wrsecs(lba, s)
  assert(#s % self.secsz == 0, "writes are whole sectors")
  for i = 0, #s // self.secsz - 1 do
    self:wrat(lba + i, 0, s, i * self.secsz + 1, (i + 1) * self.secsz)
  end
end

-- Read and write inside one sector, for the fields that are smaller
-- than one: a FAT12 entry straddling a boundary, a directory entry, the
-- free count in FSInfo.
function Fs:rdat(lba, off, n)
  return self:rdsec(lba):sub(off + 1, off + n)
end

-- The part of the sector that changed, and nothing else. from and to
-- select part of s, as string.sub means them.
function Fs:wrat(lba, off, s, from, to)
  local sec = self:rdsec(lba)

  sec:copy(off + 1, s, from, to)
  self:wrsec(lba, sec)
end

--------------------------------------------------------------------------
-- flushing
--
-- Nothing reaches the device until this runs. FAT has no journal and no
-- generation counter, so there is no ordering that makes a half-flush
-- consistent -- the most that can be said is that a sector is either
-- the old one or the new one. What sync() gives is a point where the
-- device holds everything, and that is what the callers are told.

function Fs:flush()
  if self.ndirty == 0 then return end
  local order = {}
  for lba in pairs(self.dirty) do order[#order + 1] = lba end
  table.sort(order, function(a, b) return self.dirty[a] < self.dirty[b] end)
  for _, lba in ipairs(order) do
    -- the sector goes out as it is held: the device takes a buffer.
    self.dev:write(self:secoff(lba), self.cache[lba])
    self.nwrite = self.nwrite + 1
  end
  -- Written out, so they are clean now and may be evicted.
  for lba in pairs(self.dirty) do
    if self.cache[lba] ~= nil then self.nclean = self.nclean + 1 end
  end
  self.dirty = {}
  self.ndirty = 0
  evict(self)
end

function Fs:sync()
  self:fsisync()
  self:flush()
  if self.dev.sync then self.dev:sync() end
end

-- Throw the cache away and start again from the device, which is what a
-- test wants after cutting the power and what fsck wants after a repair.
function Fs:drop()
  self:dropindex()
  self.cache = {}
  self.dirty = {}
  self.ndirty = 0
  self.nclean = 0
end

return M
