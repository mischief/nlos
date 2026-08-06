-- Making a volume, and opening one.
--
-- The geometry is the whole of FAT's design: reserved sectors, then the
-- FATs, then the root directory on FAT12 and FAT16, then the data. Four
-- regions in a fixed order, each one's start the sum of what came
-- before, and every address in the filesystem is that sum plus an
-- index. There is no indirection anywhere and nothing can be moved.
--
-- Which of the three variants a volume is follows from one number, the
-- count of data clusters, and from nothing else -- not the label, not
-- the type string in the BPB, which is documentation and is allowed to
-- lie. UEFI 13.3.1.1 puts it the same way: the variant is defined by
-- the size of the media.

local dat = require "fat.dat"
local pack = require "fat.pack"
local Fs = require "fat.obj"

require "fat.blk"
require "fat.fat"
require "fat.dir"
require "fat.fsops"

local M = {}

--------------------------------------------------------------------------
-- geometry

-- Sectors per cluster by volume size, following the table every FAT
-- formatter uses. Bigger clusters waste the tail of every file and buy
-- a shorter FAT and shorter chains; these are the points where that
-- trade has been settled the same way for thirty years.
local function defaultspc(nsec, type_)
  local mb = nsec // 2048
  if type_ == 32 then
    if mb <= 260 then return 1 end
    if mb <= 8192 then return 8 end
    if mb <= 16384 then return 16 end
    if mb <= 32768 then return 32 end
    return 64
  end
  if mb <= 16 then return 1 end
  if mb <= 128 then return 4 end
  if mb <= 256 then return 8 end
  if mb <= 512 then return 16 end
  return 32
end

-- The size of one FAT, which depends on the number of clusters, which
-- depends on the size of the FAT. Iterating settles it: each pass
-- shrinks the data region by whatever the FAT grew, so the count comes
-- down and never oscillates.
local function fatsize(g)
  local rootsecs = ((g.rootents * dat.Direntsz) + g.secsz - 1) // g.secsz
  local fatsz = 1
  local nclus
  for _ = 1, 32 do
    local datasec = g.totsec - g.rsvd - rootsecs - g.numfats * fatsz
    if datasec <= 0 then return nil, "the volume is too small" end
    nclus = datasec // g.secperclus
    local bytes
    if g.type == 12 then
      bytes = ((nclus + 2) * 3 + 1) // 2
    elseif g.type == 16 then
      bytes = (nclus + 2) * 2
    else
      bytes = (nclus + 2) * 4
    end
    local want = (bytes + g.secsz - 1) // g.secsz
    if want == fatsz then
      return fatsz, nclus, rootsecs
    end
    fatsz = want
  end
  return nil, "the geometry does not settle"
end

-- The band of cluster counts that makes a volume one variant rather
-- than another. A layout outside its band is not a matter of taste: a
-- reader computes the count and calls the volume whatever the count
-- says, so a FAT16 volume with 4000 clusters would be read as FAT12 and
-- its FAT read at the wrong width.
local function inband(type_, nclus)
  if nclus == 0 then return false end
  if type_ == 12 then return nclus < dat.Fat12max end
  if type_ == 16 then
    return nclus >= dat.Fat12max and nclus < dat.Fat16max
  end
  return nclus >= dat.Fat16max and nclus < dat.Clmask[32] - 16
end

-- Lay a variant out over a volume of this size, choosing the smallest
-- cluster that keeps the count inside the band -- the smallest wastes
-- the least at the end of every file. A caller that names a cluster
-- size gets that one or nothing.
local function layfor(type_, nsec, secsz, opts)
  local spcs = {}
  if opts.secperclus then
    spcs[1] = opts.secperclus
  else
    local first = defaultspc(nsec, type_)
    spcs[1] = first
    local spc = 1
    while spc <= 128 do
      if spc ~= first then spcs[#spcs + 1] = spc end
      spc = spc * 2
    end
  end

  for _, spc in ipairs(spcs) do
    local g = {
      type = type_,
      secsz = secsz,
      totsec = nsec,
      numfats = opts.numfats or 2,
      secperclus = spc,
      rsvd = opts.rsvd or (type_ == 32 and 32 or 1),
      rootents = (type_ == 32) and 0 or (opts.rootents or 512),
    }
    local fatsz, nclus, rootsecs = fatsize(g)
    if fatsz and inband(type_, nclus) then
      g.fatsz, g.nclus, g.rootsecs = fatsz, nclus, rootsecs
      return g
    end
  end
  return nil
end

-- Pick a variant for a volume of this size. The guess from the size
-- decides only what is tried first: the count of clusters a layout
-- actually produces is what settles it, since that is the number a
-- reader will compute.
local function pick(nsec, secsz, opts)
  if opts.type then
    local g = layfor(opts.type, nsec, secsz, opts)
    if g then return g end
    return nil, ("no FAT%d geometry fits this volume"):format(opts.type)
  end

  local mb = nsec * secsz // (1024 * 1024)
  local guess = (mb < 4) and 12 or (mb < 512) and 16 or 32
  -- After the guess, larger variants first: a volume that fits both
  -- FAT16 and FAT12 is better off as FAT16, which has a wider entry
  -- and no split nibbles.
  for _, type_ in ipairs({ guess, 32, 16, 12 }) do
    local g = layfor(type_, nsec, secsz, opts)
    if g then return g end
  end
  return nil, "no FAT geometry fits this volume"
end

M.pick = pick

--------------------------------------------------------------------------
-- laying out an opened volume
--
-- One place computes the region starts, so ream and open cannot come to
-- different conclusions about where the data begins.

local function layout(fs, g)
  fs.type = g.type
  fs.secsz = g.secsz
  fs.totsec = g.totsec
  fs.numfats = g.numfats
  fs.secperclus = g.secperclus
  fs.fatsz = g.fatsz
  fs.rootents = g.rootents
  fs.fatstart = g.rsvd
  fs.rootstart = g.rsvd + g.numfats * g.fatsz
  fs.rootsecs = g.rootsecs
  fs.firstdata = fs.rootstart + g.rootsecs
  fs.nclus = g.nclus
  fs.rootclus = g.rootclus or dat.Clfirst
end

--------------------------------------------------------------------------
-- ream
--
-- Writes a boot sector, empty FATs and an empty root, and nothing else.
-- What is not written is not read: a FAT volume has no state outside
-- these, so the data region is left exactly as it was found.

function M.ream(dev, opts)
  opts = opts or {}
  local secsz = opts.secsz or dat.Secsz
  local base = opts.base or 0
  local size = opts.size or (dev:size() - base)
  local nsec = size // secsz
  if nsec < 128 then return nil, "the volume is too small" end

  local g, err = pick(nsec, secsz, opts)
  if not g then return nil, err end
  if g.type == 32 then g.rootclus = dat.Clfirst end

  local fs = setmetatable({
    dev = dev, base = base, readonly = false,
    clock = opts.clock,
    nextfree = dat.Clfirst, fsidirty = false,
  }, Fs)
  fs:cacheinit(opts.cache)
  layout(fs, g)

  local boot = pack.packbpb({
    type = g.type,
    oem = opts.oem,
    bytspersec = g.secsz,
    secperclus = g.secperclus,
    rsvdseccnt = g.rsvd,
    numfats = g.numfats,
    rootentcnt = g.rootents,
    totsec16 = (nsec < 0x10000) and nsec or 0,
    totsec32 = (nsec < 0x10000) and 0 or nsec,
    fatsz16 = (g.type ~= 32) and g.fatsz or 0,
    fatsz32 = (g.type == 32) and g.fatsz or 0,
    rootclus = g.rootclus,
    media = opts.media or 0xF8,
    hiddsec = opts.hiddsec or 0,
    volid = opts.volid or (fs:now() & 0xFFFFFFFF),
    vollab = opts.label,
    fsinfo = 1,
    bkbootsec = (g.type == 32) and 6 or 0,
  })
  fs:wrsec(0, boot)

  -- FAT32 keeps a spare copy of the boot sector and an FSInfo sector,
  -- both in the reserved region. A firmware that finds sector 0
  -- unreadable is expected to look at the copy, so it is written and
  -- kept identical.
  if g.type == 32 then
    fs.fsinfosec = 1
    fs:wrsec(1, pack.packfsinfo(nil, dat.Clfirst, secsz))
    if g.rsvd > 6 then
      fs:wrsec(6, boot)
      fs:wrsec(7, pack.packfsinfo(nil, dat.Clfirst, secsz))
    end
  end

  -- Clear the FATs and both root regions. Entry 0 holds the media byte
  -- with the rest set, and entry 1 an end mark whose top bits are the
  -- dirty flags a driver may set; a fresh volume is clean, so they are
  -- all ones.
  local zero = string.rep("\0", secsz)
  for i = 0, g.numfats * g.fatsz - 1 do
    fs:wrsec(fs.fatstart + i, zero)
  end
  fs:fatset(0, (0xFFFFFF00 | (opts.media or 0xF8)) & dat.Clmask[g.type])
  fs:fatset(1, dat.Cleof[g.type])

  for i = 0, g.rootsecs - 1 do fs:wrsec(fs.rootstart + i, zero) end

  if g.type == 32 then
    -- The root is a cluster like any other, so it is allocated as one.
    local c = fs:alloc(nil)
    assert(c == dat.Clfirst, "the root did not land in the first cluster")
    for i = 0, g.secperclus - 1 do fs:wrsec(fs:clusterlba(c) + i, zero) end
  end

  fs.freecount = fs:countfree()
  fs.fsidirty = true
  if opts.label then fs:setlabel(opts.label) end
  fs:sync()
  return fs
end

--------------------------------------------------------------------------
-- open
--
-- Everything here is checked before it is used. A BPB is 512 bytes of
-- whatever was on the disk, and a field taken on trust turns a corrupt
-- volume into an address computed from nonsense.

local function bad(what) return nil, "not a FAT volume: " .. what end

function M.open(dev, opts)
  opts = opts or {}
  local base = opts.base or 0
  local boot, err = dev:read(base, dat.Secsz)
  if not boot then return nil, err end

  local b, berr = pack.unpackbpb(boot)
  if not b then return bad(berr) end
  if b.bootsig ~= dat.Bootsig then return bad("no boot signature") end
  if b.bytspersec ~= 512 and b.bytspersec ~= 1024
    and b.bytspersec ~= 2048 and b.bytspersec ~= 4096 then
    return bad("sector size " .. b.bytspersec)
  end
  local spc = b.secperclus
  if spc == 0 or (spc & (spc - 1)) ~= 0 or spc > 128 then
    return bad("sectors per cluster " .. spc)
  end
  if b.numfats == 0 then return bad("no FATs") end
  if b.rsvdseccnt == 0 then return bad("no reserved sectors") end

  local totsec = (b.totsec16 ~= 0) and b.totsec16 or b.totsec32
  local fatsz = (b.fatsz16 ~= 0) and b.fatsz16 or b.fatsz32
  if totsec == 0 then return bad("no sectors") end
  if fatsz == 0 then return bad("no FAT") end

  local rootsecs = ((b.rootentcnt * dat.Direntsz) + b.bytspersec - 1)
    // b.bytspersec
  local firstdata = b.rsvdseccnt + b.numfats * fatsz + rootsecs
  if firstdata >= totsec then return bad("no data region") end
  local nclus = (totsec - firstdata) // spc
  if nclus == 0 then return bad("no clusters") end

  local type_ = (nclus < dat.Fat12max) and 12
    or (nclus < dat.Fat16max) and 16 or 32
  if type_ == 32 and b.rootentcnt ~= 0 then
    return bad("FAT32 with a fixed root directory")
  end
  if type_ ~= 32 and b.rootentcnt == 0 then
    return bad("FAT12 or FAT16 with no root directory")
  end

  local devsec = (dev:size() - base) // b.bytspersec
  if totsec > devsec then
    return bad(("%d sectors claimed, %d present"):format(totsec, devsec))
  end

  local fs = setmetatable({
    dev = dev, base = base,
    readonly = opts.readonly or false,
    clock = opts.clock,
    nextfree = dat.Clfirst, fsidirty = false,
    bpb = b,
    label = (b.vollab and b.vollab:gsub(" +$", "")) or nil,
  }, Fs)
  fs:cacheinit(opts.cache)
  layout(fs, {
    type = type_, secsz = b.bytspersec, totsec = totsec,
    numfats = b.numfats, secperclus = spc, fatsz = fatsz,
    rootents = b.rootentcnt, rsvd = b.rsvdseccnt,
    rootsecs = rootsecs, nclus = nclus,
    rootclus = (type_ == 32) and b.rootclus or nil,
  })

  if type_ == 32 then
    if not fs:validclus(fs.rootclus) then
      return bad("the root cluster is out of range")
    end
    if b.fsinfo ~= 0 and b.fsinfo ~= 0xFFFF and b.fsinfo < b.rsvdseccnt then
      fs.fsinfosec = b.fsinfo
      local fsi = pack.unpackfsinfo(fs:rdsec(b.fsinfo))
      -- The hint is used as a starting point and never as an answer:
      -- a wrong next-free costs a scan, and the free count is only
      -- reported after it has been recomputed.
      if fsi and fsi.next ~= dat.Fsinosuch and fs:validclus(fsi.next) then
        fs.nextfree = fsi.next
      end
    end
  end

  -- The label is kept in two places and they are allowed to disagree.
  -- The entry in the root is the one a reader uses, so a scan of the
  -- root -- which sets fs.label when it meets a volume entry -- has the
  -- last word over what the BPB says.
  fs:scandir(fs:rootdir(), function() end)

  if opts.freecount ~= false then fs.freecount = fs:countfree() end
  return fs
end

--------------------------------------------------------------------------
-- what the volume is

function Fs:info()
  return {
    type = self.type,
    label = self.label,
    secsz = self.secsz,
    secperclus = self.secperclus,
    clustersz = self:clustersz(),
    totsec = self.totsec,
    numfats = self.numfats,
    fatsz = self.fatsz,
    fatstart = self.fatstart,
    rootstart = (self.type ~= 32) and self.rootstart or nil,
    rootents = self.rootents,
    rootclus = (self.type == 32) and self.rootclus or nil,
    firstdata = self.firstdata,
    nclus = self.nclus,
    free = self.freecount,
    size = self.nclus * self:clustersz(),
  }
end

return M
