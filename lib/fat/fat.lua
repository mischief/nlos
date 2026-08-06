-- The file allocation table: the array that gives FAT its name.
--
-- One entry per cluster, holding the number of the next cluster in the
-- same file, or an end mark, or zero for free. A file is therefore a
-- linked list walked one lookup at a time, and nothing on disk records
-- a file's clusters in any other place. That is the format's central
-- weakness and this module is where it is felt.
--
-- Three widths. 16 and 32 bits are array indexing. 12 is not: an entry
-- is a byte and a half, every other one is split across a byte
-- boundary, and a pair of them can straddle a sector. Everything below
-- that treats a FAT12 entry as two overlapping bytes is doing so on
-- purpose.

local dat = require "fat.dat"
local pack = require "fat.pack"
local Fs = require "fat.obj"

local M = {}

local spack, sunpack, byte = string.pack, string.unpack, string.byte

--------------------------------------------------------------------------
-- where a cluster lives

function Fs:clusterlba(c)
  assert(c >= dat.Clfirst, "not a data cluster")
  return self.firstdata + (c - dat.Clfirst) * self.secperclus
end

function Fs:clustersz()
  return self.secperclus * self.secsz
end

function Fs:validclus(c)
  return c >= dat.Clfirst and c < self.nclus + dat.Clfirst
end

function Fs:iseof(c)
  return c >= dat.Cleofmin[self.type]
end

function Fs:isbad(c)
  return c == dat.Clbad[self.type]
end

--------------------------------------------------------------------------
-- one entry
--
-- The byte offset of an entry, and which FAT copy is live. ExtFlags on
-- FAT32 can name a single active copy with mirroring off; when
-- mirroring is on -- and it always is on anything this writes -- every
-- copy is kept identical and a read may use the first.

local function entoff(fs, c)
  if fs.type == 12 then
    return c + (c >> 1)             -- c * 3 / 2, exactly
  elseif fs.type == 16 then
    return c * 2
  end
  return c * 4
end

function Fs:fatget(c)
  assert(c >= 0 and c < self.nclus + dat.Clfirst, "cluster out of range")
  local off = entoff(self, c)
  local lba = self.fatstart + off // self.secsz
  local o = off % self.secsz

  if self.type == 12 then
    -- The two bytes can be in different sectors, so they are fetched
    -- one at a time rather than as a pair.
    local lo = byte(self:rdsec(lba), o + 1)
    local hi
    if o + 1 < self.secsz then
      hi = byte(self:rdsec(lba), o + 2)
    else
      hi = byte(self:rdsec(lba + 1), 1)
    end
    local v = lo | (hi << 8)
    if (c & 1) == 1 then return v >> 4 end
    return v & 0x0FFF
  elseif self.type == 16 then
    return sunpack("<I2", self:rdsec(lba), o + 1)
  end
  -- The top four bits of a FAT32 entry are reserved and belong to
  -- whoever set them, so a read masks them off and a write puts them
  -- back untouched.
  return sunpack("<I4", self:rdsec(lba), o + 1) & dat.Clmask[32]
end

function Fs:fatset(c, v)
  self.cursor = nil
  assert(c >= dat.Clfree and c < self.nclus + dat.Clfirst, "cluster out of range")
  local off = entoff(self, c)

  for i = 0, self.numfats - 1 do
    local base = self.fatstart + i * self.fatsz
    local lba = base + off // self.secsz
    local o = off % self.secsz

    if self.type == 12 then
      local lo = byte(self:rdsec(lba), o + 1)
      local hilba, hio = lba, o + 1
      if o + 1 >= self.secsz then hilba, hio = lba + 1, 0 end
      local hi = byte(self:rdsec(hilba), hio + 1)
      local cur = lo | (hi << 8)
      local new
      if (c & 1) == 1 then
        new = (cur & 0x000F) | ((v & 0x0FFF) << 4)
      else
        new = (cur & 0xF000) | (v & 0x0FFF)
      end
      self:wrat(lba, o, spack("<I1", new & 0xFF))
      self:wrat(hilba, hio, spack("<I1", (new >> 8) & 0xFF))
    elseif self.type == 16 then
      self:wrat(lba, o, spack("<I2", v & 0xFFFF))
    else
      local cur = sunpack("<I4", self:rdsec(lba), o + 1)
      local new = (cur & 0xF0000000) | (v & dat.Clmask[32])
      self:wrat(lba, o, spack("<I4", new))
    end
  end
end

--------------------------------------------------------------------------
-- chains

-- Every cluster of a file, in order. A chain that loops is an error and
-- not an infinite walk: the count of clusters bounds the length, so a
-- walk longer than that has met itself.
function Fs:chain(c, max)
  local out = {}
  local n = 0
  while self:validclus(c) do
    out[#out + 1] = c
    n = n + 1
    if max and n >= max then break end
    if n > self.nclus then
      error("cluster chain loops at " .. c, 0)
    end
    c = self:fatget(c)
  end
  if c ~= 0 and not self:iseof(c) and not self:validclus(c) then
    error(("chain ends at %d, which is not a cluster"):format(c), 0)
  end
  return out
end

-- The nth cluster of a chain, without building the list. This is the
-- lookup a read or a write at an offset does, and it is linear: nothing
-- on disk records where a file's clusters are except the chain itself,
-- so the nth is found by counting to it.
--
-- What can be avoided is counting from the start every time. One cursor
-- remembers where the last walk of a chain ended, so reading or writing
-- a file from beginning to end costs one step per cluster rather than
-- one walk per call. Any change to a FAT entry drops it, since a link
-- it walked through may no longer be the link that is there.
function Fs:clusat(first, n)
  local c, at = first, 0
  local cur = self.cursor
  if cur and cur.first == first and cur.n <= n then
    c, at = cur.clus, cur.n
  end
  for _ = at + 1, n do
    if not self:validclus(c) then return nil end
    c = self:fatget(c)
  end
  if not self:validclus(c) then return nil end
  self.cursor = { first = first, n = n, clus = c }
  return c
end

--------------------------------------------------------------------------
-- allocation
--
-- The search starts where the last one stopped, wraps once, and gives
-- up where it began. FSInfo carries that position across a mount, which
-- is all it is good for -- a stale hint costs a scan, never a wrong
-- answer.

function Fs:alloc(prev)
  local first = dat.Clfirst
  local last = self.nclus + dat.Clfirst - 1
  local start = self.nextfree
  if start < first or start > last then start = first end

  local c = start
  repeat
    if self:fatget(c) == dat.Clfree then
      self:fatset(c, dat.Cleof[self.type])
      self.nextfree = (c + 1 > last) and first or (c + 1)
      if self.freecount then self.freecount = self.freecount - 1 end
      self.fsidirty = true
      if prev then self:fatset(prev, c) end
      return c
    end
    c = (c + 1 > last) and first or (c + 1)
  until c == start
  return nil, "no space left on the volume"
end

-- Allocate n clusters onto the end of a chain, and hand back nothing if
-- they are not all there: a half-grown file whose write then fails is
-- worse than a write that fails first.
function Fs:allocn(prev, n)
  local got = {}
  local at = prev
  for _ = 1, n do
    local c, err = self:alloc(at)
    if not c then
      for i = #got, 1, -1 do self:fatset(got[i], dat.Clfree) end
      -- The end mark goes back on the cluster the chain ended at before
      -- any of this, not on the one the walk reached: that one has just
      -- been freed, and pointing a live chain at it is the cross-link
      -- this rollback exists to avoid.
      if prev then self:fatset(prev, dat.Cleof[self.type]) end
      self.freecount = self.freecount and (self.freecount + #got)
      return nil, err
    end
    got[#got + 1] = c
    at = c
  end
  return got
end

function Fs:free(c)
  local n = 0
  while self:validclus(c) do
    local nxt = self:fatget(c)
    self:fatset(c, dat.Clfree)
    n = n + 1
    if self.freecount then self.freecount = self.freecount + 1 end
    if n > self.nclus then error("cluster chain loops at " .. c, 0) end
    c = nxt
  end
  self.fsidirty = true
  return n
end

-- Cut a chain after n clusters and free what follows. n of zero frees
-- the whole chain, which is what truncating a file to nothing does.
function Fs:truncchain(first, n)
  if n == 0 then
    if self:validclus(first) then self:free(first) end
    return 0
  end
  local c = self:clusat(first, n - 1)
  if not c then return first end
  local nxt = self:fatget(c)
  self:fatset(c, dat.Cleof[self.type])
  if self:validclus(nxt) then self:free(nxt) end
  return first
end

--------------------------------------------------------------------------
-- the free count
--
-- Counted by reading every entry, which is the only source that is
-- always right. On FAT32 the answer is cached back into FSInfo; on the
-- other two there is nowhere to put it and it is recounted on demand.

function Fs:countfree()
  local n = 0
  for c = dat.Clfirst, self.nclus + dat.Clfirst - 1 do
    if self:fatget(c) == dat.Clfree then n = n + 1 end
  end
  return n
end

function Fs:fsisync()
  if self.type ~= 32 or not self.fsinfosec or not self.fsidirty then return end
  self:wrsec(self.fsinfosec,
    pack.packfsinfo(self.freecount, self.nextfree, self.secsz))
  self.fsidirty = false
end

return M
