-- Directories: a file whose contents are 32-byte entries.
--
-- Two shapes, and the difference runs through everything here. On FAT32
-- every directory is an ordinary cluster chain and grows. On FAT12 and
-- FAT16 the root is a fixed run of sectors between the FATs and the
-- data region, holds exactly RootEntCnt entries, and cannot grow -- so
-- a root that fills is full, and that is the format and not a bug.
--
-- A named entry is one short entry, optionally preceded by the long
-- name entries that spell its name out in UCS-2. The set is contiguous
-- and the long entries carry a checksum of the short name, so a set
-- that has come adrift from its short entry is detected and skipped.

local dat = require "fat.dat"
local pack = require "fat.pack"
local Fs = require "fat.obj"

local M = {}

local byte, rep, sub = string.byte, string.rep, string.sub

--------------------------------------------------------------------------
-- naming a directory
--
-- A directory is named by its first cluster, with zero meaning the
-- fixed root on FAT12 and FAT16. FAT32 has no fixed root: its root is
-- a chain like any other, so a zero there is turned into the real
-- cluster number the BPB records.

function Fs:rootdir()
  if self.type == 32 then return { clus = self.rootclus } end
  return { root = true }
end

function Fs:dirof(clus)
  if clus == 0 or clus == nil then return self:rootdir() end
  return { clus = clus }
end

function Fs:isroot(d)
  if d.root then return true end
  return self.type == 32 and d.clus == self.rootclus
end

--------------------------------------------------------------------------
-- slots
--
-- A slot is an entry-sized place in a directory, numbered from zero.
-- Turning one into a sector is the only arithmetic in this module that
-- has to know which of the two shapes it is looking at.

function Fs:dirslots(d)
  if d.root then return self.rootents end
  local n = #self:chain(d.clus)
  return n * self:clustersz() // dat.Direntsz
end

local function slotlba(fs, d, i)
  local off = i * dat.Direntsz
  if d.root then
    if i >= fs.rootents then return nil end
    return fs.rootstart + off // fs.secsz, off % fs.secsz
  end
  local csz = fs:clustersz()
  local c = fs:clusat(d.clus, off // csz)
  if not c then return nil end
  local within = off % csz
  return fs:clusterlba(c) + within // fs.secsz, within % fs.secsz
end

function Fs:rdslot(d, i)
  local lba, off = slotlba(self, d, i)
  if not lba then return nil end
  return self:rdat(lba, off, dat.Direntsz)
end

function Fs:wrslot(d, i, s)
  assert(#s == dat.Direntsz, "a slot is one directory entry")
  local lba, off = slotlba(self, d, i)
  if not lba then error("slot " .. i .. " is past the directory", 0) end
  self:wrat(lba, off, s)
end

-- Add one cluster to a directory and fill it with end markers, so a
-- scan that walks into it stops rather than reading whatever the
-- cluster held before.
function Fs:growdir(d)
  if d.root then return nil, "the root directory is full" end
  local chain = self:chain(d.clus)
  local c, err = self:alloc(chain[#chain])
  if not c then return nil, err end
  local zero = rep("\0", self.secsz)
  for i = 0, self.secperclus - 1 do
    self:wrsec(self:clusterlba(c) + i, zero)
  end
  return c
end

--------------------------------------------------------------------------
-- reading entries
--
-- The walk is forward and stateful: long entries pile up until a short
-- one arrives and claims them. Anything that breaks the run -- a free
-- slot, a wrong ordinal, a checksum that does not match -- throws the
-- pile away, which is what makes a half-deleted set harmless.

local function fold(s)
  return (s:upper())
end

M.fold = fold

-- Iterate the live entries of a directory. Each is a table:
--
--      name   the long name if there is one, else the short one
--      short  the eleven raw bytes
--      attr   the attribute byte
--      clus   the first cluster, or zero for an empty file
--      size   the length in bytes, zero for a directory
--      slot   the index of the short entry
--      first  the index of the first slot of the set
function Fs:scandir(d, fn)
  local n = self:dirslots(d)
  local pending, want, sum, first = {}, nil, nil, nil
  local i = 0
  while i < n do
    local s = self:rdslot(d, i)
    if not s then break end
    local b0 = byte(s, 1)
    if b0 == dat.Eend then
      break
    elseif b0 == dat.Efree then
      pending, want, sum, first = {}, nil, nil, nil
    else
      local attr = byte(s, 12)
      if (attr & dat.Along) == dat.Along then
        local l = pack.longent(s)
        if l.last then
          pending, want, sum, first = {}, l.ord, l.chksum, i
        end
        if want and l.ord == want and l.chksum == sum then
          pending[l.ord] = l.frag
          want = want - 1
        else
          pending, want, sum, first = {}, nil, nil, nil
        end
      else
        local e = pack.unpackdirent(s)
        local name
        -- a complete set, in order, whose checksum matches this entry
        if want == 0 and sum == pack.chksum(e.name) then
          local u = {}
          for k = 1, #pending do u[k] = pending[k] end
          name = pack.ucs2toutf8(table.concat(u))
        end
        if (attr & dat.Avolume) ~= 0 then
          self.label = pack.shortname(e.name)
        else
          local ent = {
            name = name or pack.shortcased(e.name, e.ntres),
            short = e.name,
            attr = attr,
            clus = e.clus,
            size = e.size,
            mtime = pack.unpackdatetime(e.wrtdate, e.wrttime),
            ctime = pack.unpackdatetime(e.crtdate, e.crttime),
            slot = i,
            first = (name and first) or i,
            long = name ~= nil,
          }
          local stop = fn(ent)
          if stop then return stop end
        end
        pending, want, sum, first = {}, nil, nil, nil
      end
    end
    i = i + 1
  end
end

-- One entry, rebuilt from the slot its short record sits in. The long
-- name entries are the slots immediately before it, so the set is
-- picked up by walking backwards while the ordinals count down to one
-- and the checksum keeps matching -- the same test scandir applies
-- going forwards, from the other end.
function Fs:entat(d, slot)
  local s = self:rdslot(d, slot)
  if not s then return nil end
  local b0 = byte(s, 1)
  if b0 == dat.Eend or b0 == dat.Efree then return nil end
  local e = pack.unpackdirent(s)

  local name, first = nil, slot
  local sum = pack.chksum(e.name)
  local frags, want = {}, 1
  local i = slot - 1
  while i >= 0 do
    local l = self:rdslot(d, i)
    if not l or byte(l, 1) == dat.Efree or byte(l, 1) == dat.Eend then break end
    if (byte(l, 12) & dat.Along) ~= dat.Along then break end
    local ent = pack.longent(l)
    if ent.ord ~= want or ent.chksum ~= sum then break end
    frags[ent.ord] = ent.frag
    first = i
    if ent.last then
      name = pack.ucs2toutf8(table.concat(frags))
      break
    end
    want = want + 1
    i = i - 1
  end

  return {
    name = name or pack.shortcased(e.name, e.ntres),
    short = e.name,
    attr = e.attr,
    clus = e.clus,
    size = e.size,
    mtime = pack.unpackdatetime(e.wrtdate, e.wrttime),
    ctime = pack.unpackdatetime(e.crtdate, e.crttime),
    slot = slot,
    first = first,
    long = name ~= nil,
  }
end

--------------------------------------------------------------------------
-- the index
--
-- A directory is a flat list, so finding a name, finding a free run of
-- slots, and finding a short name nothing else holds are each a walk of
-- the whole thing. Doing all three on every create makes filling a
-- directory cost the square of its size, which is what a FAT driver
-- with a few thousand files in one directory is famous for.
--
-- So the first walk of a directory is remembered. What is kept is one
-- slot number per name and nothing else -- the entry itself is rebuilt
-- from that slot, which costs a read of a sector that is already in the
-- cache. Holding the entries instead would cost a kilobyte a file,
-- which is the wrong trade on the machines this is aimed at.
--
-- The set of short names is built only when a long name has to be
-- given one, since a directory of 8.3 names never asks.
--
-- Every path that changes a directory goes through mkent, delent and
-- growdir, which keep the index in step; scandir and readdir do not use
-- it and always read the disk, so the checker still sees what is
-- actually there.

local Ncached = 16      -- directories held, one dropped to make room

local function dirkey(d)
  return d.root and "/" or d.clus
end

function Fs:dirindex(d)
  self.dirs = self.dirs or {}
  local k = dirkey(d)
  local ix = self.dirs[k]
  if ix then return ix end

  -- One dropped rather than all of them. A single walk touches every
  -- directory on the path and loading a library touches several, so
  -- emptying the table makes the next walk rebuild what it just used --
  -- and rebuilding one is a scan of the whole directory.
  local n = 0

  for _ in pairs(self.dirs) do n = n + 1 end
  if n >= Ncached then
    for k2 in pairs(self.dirs) do
      self.dirs[k2] = nil
      break
    end
  end

  ix = { names = {}, nslots = self:dirslots(d), freefrom = 0 }
  self:scandir(d, function(e)
    ix.names[fold(e.name)] = e.slot
  end)
  self.dirs[k] = ix
  return ix
end

-- Short names are held as hashes of their eleven bytes rather than as
-- the bytes, which is half the memory for a set that is only ever asked
-- "is this one taken". A collision makes a create pick a different name
-- than it needed to and costs nothing else.
local function shorthash(s)
  local h = 0
  for i = 1, 11 do h = ((h << 5) - h + byte(s, i)) & 0x7FFFFFFF end
  return h
end

M.shorthash = shorthash

-- The short names this directory holds, built on demand: a directory of
-- 8.3 names never asks, since nothing in it needs a name made up.
function Fs:dirshorts(d)
  local ix = self:dirindex(d)
  if not ix.shorts then
    ix.shorts = {}
    self:scandir(d, function(e) ix.shorts[shorthash(e.short)] = true end)
  end
  return ix.shorts
end

function Fs:dropindex(d)
  if not self.dirs then return end
  if d then self.dirs[dirkey(d)] = nil else self.dirs = {} end
end

function Fs:readdir(d)
  local out = {}
  self:scandir(d, function(e)
    if e.name ~= "." and e.name ~= ".." then out[#out + 1] = e end
  end)
  return out
end

-- FAT names are compared without case, which UEFI 13.3.1.2 states as
-- the rule for uniqueness within a directory. Folding is ASCII only:
-- full UCS-2 case folding needs a table this has no business carrying,
-- and getting it wrong would make two names collide that a firmware
-- reader keeps apart.
function Fs:lookup(d, name)
  local slot = self:dirindex(d).names[fold(name)]
  if not slot then return nil end
  return self:entat(d, slot)
end

function Fs:isempty(d)
  local found = self:scandir(d, function(e)
    if e.name ~= "." and e.name ~= ".." then return true end
  end)
  return not found
end

--------------------------------------------------------------------------
-- writing entries

-- A run of n free slots, growing the directory until there is one. Free
-- means deleted or never used; the end marker is treated as the start
-- of an unbounded run, since everything past it is unused by
-- definition.
function Fs:findfree(d, n)
  local ix = self:dirindex(d)
  local total = ix.nslots
  local run, start = 0, nil
  local i = ix.freefrom
  while i < total do
    local s = self:rdslot(d, i)
    if not s then break end
    local b0 = byte(s, 1)
    if b0 == dat.Efree or b0 == dat.Eend then
      if run == 0 then start = i end
      run = run + 1
      if run >= n then return start end
    else
      run, start = 0, nil
    end
    i = i + 1
  end
  -- Nothing large enough inside; add a cluster and try again. Each
  -- pass gains a whole cluster of slots, so this ends.
  while true do
    local before = total
    local ok, err = self:growdir(d)
    if not ok then return nil, err end
    total = self:dirslots(d)
    ix.nslots = total
    if run > 0 and start ~= nil and start + run == before then
      -- the tail run continues into what was just added
      if run + (total - before) >= n then return start end
      run = run + (total - before)
    else
      start, run = before, total - before
      if run >= n then return start end
    end
  end
end

-- Pick a short name for a long one that no entry in the directory
-- already holds. The tail count is bounded so a directory full of
-- near-identical names fails rather than scanning forever.
local function uniqueshort(fs, d, name)
  local taken = fs:dirshorts(d)
  local base, ext = pack.stems(name)
  -- A few sequential tails first, because ~1 is what a person reading
  -- the directory expects to see and what other systems produce.
  for n = 1, 4 do
    local s = pack.mangle(name, n, base, ext)
    if not taken[shorthash(s)] then return s end
  end
  -- Past that the names in this directory evidently share a stem, and
  -- counting further would walk the whole directory for every file. A
  -- hash of the name lands somewhere else on the first try.
  for seed = 0, 65535 do
    local s = pack.hashshort(name, seed, base, ext)
    if not taken[shorthash(s)] then return s end
  end
  return nil, "no short name left for " .. name
end

function Fs:mkent(d, name, attr, clus, size, now)
  if #name == 0 or #name > dat.Maxname then
    return nil, "bad name"
  end
  if name:find("[/\\%z]") then return nil, "bad name" end

  local short, ntres = pack.mkshort(name)
  local nlong = 0
  if not short then
    -- The name does not fit 8.3, or fits only with its case thrown
    -- away. It gets a long entry, and the short entry beside it gets a
    -- mangled name that no other entry in this directory holds -- so an
    -- old reader that ignores long entries still sees a unique name.
    local err
    short, err = uniqueshort(self, d, name)
    if not short then return nil, err end
    ntres = 0
    nlong = pack.nlong(name)
    if not nlong then return nil, "name is not UCS-2 text" end
  end

  local start, err = self:findfree(d, nlong + 1)
  if not start then return nil, err end

  if nlong > 0 then
    local ents, lerr = pack.packlong(name, short)
    if not ents then return nil, lerr end
    for k, s in ipairs(ents) do self:wrslot(d, start + k - 1, s) end
  end

  now = now or self:now()
  local e = {
    name = short,
    ntres = ntres,
    attr = attr,
    clus = clus or 0,
    size = size or 0,
    crtdate = pack.packdate(now), crttime = pack.packtime(now),
    wrtdate = pack.packdate(now), wrttime = pack.packtime(now),
    lstaccdate = pack.packdate(now),
  }
  self:wrslot(d, start + nlong, pack.packdirent(e))

  local ix = self:dirindex(d)
  if ix.shorts then ix.shorts[shorthash(short)] = true end
  -- The free-slot bound moves past what was just taken. It is a bound
  -- and not a position: a shorter run before it may still be free, so a
  -- create can skip over one. A delete puts the bound back, which is
  -- what keeps a directory that is churned from growing without end.
  ix.freefrom = start + nlong + 1

  -- Nothing marks the end here. A run taken from deleted slots leaves
  -- whatever followed them alone, and a run taken from the unused tail
  -- is followed by slots that are still zero, which is the end marker
  -- already. Writing one would bury live entries.
  local ent = {
    name = name, short = short, ntres = ntres, attr = attr, clus = clus or 0,
    size = size or 0, slot = start + nlong, first = start,
    long = nlong > 0,
  }
  ix.names[fold(name)] = ent.slot
  return ent
end

-- Write an entry's short record back, keeping every field this layer
-- does not own.
function Fs:updent(d, ent, changes)
  local s = self:rdslot(d, ent.slot)
  local e = pack.unpackdirent(s)
  for k, v in pairs(changes) do e[k] = v end
  if changes.clus then e.clus = changes.clus end
  self:wrslot(d, ent.slot, pack.packdirent(e))
  for k, v in pairs(changes) do
    if k == "clus" or k == "size" then ent[k] = v end
  end
end

function Fs:delent(d, ent)
  local free = string.char(dat.Efree)
  for i = ent.first, ent.slot do
    local s = self:rdslot(d, i)
    self:wrslot(d, i, free .. sub(s, 2))
  end
  local ix = self:dirindex(d)
  ix.names[fold(ent.name)] = nil
  if ix.shorts then ix.shorts[shorthash(ent.short)] = nil end
  if ent.first < ix.freefrom then ix.freefrom = ent.first end
end

--------------------------------------------------------------------------
-- the volume label
--
-- Kept twice: in the BPB, where it is a comment, and as an entry in the
-- root directory carrying the volume attribute, which is where a reader
-- actually looks. A volume with one and not the other is what fsck
-- tools report, so both are written together.

function Fs:setlabel(name, now)
  self:writable()
  local d = self:rootdir()
  local raw = pack.padlabel(name)
  -- scandir does not yield the volume entry, so the slots are walked
  -- directly here: an existing label is replaced, and a volume that has
  -- none gets one in the first free slot.
  local slot
  local n = self:dirslots(d)
  for i = 0, n - 1 do
    local s = self:rdslot(d, i)
    if not s then break end
    local b0 = byte(s, 1)
    if b0 == dat.Eend then
      slot = slot or i
      break
    elseif b0 ~= dat.Efree and (byte(s, 12) & dat.Along) ~= dat.Along
      and (byte(s, 12) & dat.Avolume) ~= 0 then
      slot = i
      break
    end
  end
  if not slot then
    local err
    slot, err = self:findfree(d, 1)
    if not slot then return nil, err end
  end
  now = now or self:now()
  self:wrslot(d, slot, pack.packdirent({
    name = raw, attr = dat.Avolume, clus = 0, size = 0,
    wrtdate = pack.packdate(now), wrttime = pack.packtime(now),
  }))
  self.label = (raw:gsub(" +$", ""))
  -- The label is written to a slot directly rather than through mkent,
  -- so the index no longer describes the root.
  self:dropindex(d)
  return true
end

--------------------------------------------------------------------------
-- making one

-- A new directory is one cleared cluster holding . and .. and nothing
-- else. The .. of a directory whose parent is the root is written as
-- cluster zero even on FAT32, where the root has a real cluster number:
-- that is what the format says and what every reader expects.
function Fs:mkdirclus(parent, now)
  local c, err = self:alloc(nil)
  if not c then return nil, err end
  local zero = rep("\0", self.secsz)
  for i = 0, self.secperclus - 1 do
    self:wrsec(self:clusterlba(c) + i, zero)
  end

  local d = { clus = c }
  now = now or self:now()
  local function dot(name, clus)
    return pack.packdirent({
      name = name, attr = dat.Adir, clus = clus, size = 0,
      crtdate = pack.packdate(now), crttime = pack.packtime(now),
      wrtdate = pack.packdate(now), wrttime = pack.packtime(now),
    })
  end
  local pclus = parent.clus or 0
  if self.type == 32 and pclus == self.rootclus then pclus = 0 end
  self:wrslot(d, 0, dot(".          ", c))
  self:wrslot(d, 1, dot("..         ", pclus))
  return c
end

return M
