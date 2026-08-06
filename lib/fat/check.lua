-- The consistency checker.
--
-- FAT has no checksums and no redundancy beyond the second FAT, so
-- everything here is cross-referencing: the directory tree says which
-- clusters belong to which file, and the FAT says which cluster follows
-- which. The two are independent statements about the same thing and
-- checking one against the other is all the evidence there is.
--
-- What can go wrong, in the order the passes look for it:
--
--   * a chain that points outside the volume, or at a bad cluster
--   * a chain that loops
--   * two files claiming the same cluster -- a cross-link, the failure
--     that makes writing to a damaged FAT volume destructive
--   * a chain longer or shorter than the size its directory entry gives
--   * a cluster marked used that nothing reaches -- a lost chain
--   * the FAT copies disagreeing
--   * a directory whose .. does not point at its parent

local dat = require "fat.dat"
local pack = require "fat.pack"
local Fs = require "fat.obj"

local M = {}

local function walkchain(fs, c, owner, seen, fail, what)
  local n = 0
  while true do
    if c == dat.Clfree then
      fail[#fail + 1] = ("%s: chain runs into a free cluster"):format(what)
      return n
    end
    if fs:isbad(c) then
      fail[#fail + 1] = ("%s: chain runs into a bad cluster %d")
        :format(what, c)
      return n
    end
    if not fs:validclus(c) then
      fail[#fail + 1] = ("%s: cluster %d is outside the volume")
        :format(what, c)
      return n
    end
    if seen[c] then
      if seen[c] == owner then
        fail[#fail + 1] = ("%s: chain loops at cluster %d"):format(what, c)
      else
        fail[#fail + 1] = ("%s: cluster %d is also held by %s")
          :format(what, c, seen[c])
      end
      return n
    end
    seen[c] = owner
    n = n + 1
    local nxt = fs:fatget(c)
    if fs:iseof(nxt) then return n end
    c = nxt
  end
end

-- Walk the tree, checking every chain it names and every directory it
-- reaches. Depth is bounded by the number of clusters, since a
-- directory loop would otherwise be a descent that never returns.
local function walkdir(fs, d, path, seen, fail, depth)
  if depth > 64 then
    fail[#fail + 1] = path .. ": directories nested too deep"
    return
  end

  for _, e in ipairs(fs:readdir(d)) do
    local at = (path == "/") and ("/" .. e.name) or (path .. "/" .. e.name)
    local isdir = (e.attr & dat.Adir) ~= 0

    if e.clus ~= 0 then
      local n = walkchain(fs, e.clus, at, seen, fail, at)
      if not isdir then
        local want = (e.size + fs:clustersz() - 1) // fs:clustersz()
        if n < want then
          fail[#fail + 1] = ("%s: %d bytes but only %d clusters of %d")
            :format(at, e.size, n, want)
        elseif n > want then
          fail[#fail + 1] = ("%s: %d clusters held for %d bytes")
            :format(at, n, e.size)
        end
      end
    elseif isdir then
      fail[#fail + 1] = at .. ": a directory with no cluster"
    elseif e.size ~= 0 then
      fail[#fail + 1] = ("%s: %d bytes and no clusters"):format(at, e.size)
    end

    if isdir and e.clus ~= 0 and fs:validclus(e.clus) then
      local sub = fs:dirof(e.clus)
      -- . points at the directory itself and .. at its parent, which is
      -- the only back pointer the format has and the only way a
      -- recovered directory can be put back where it belongs.
      local dot = pack.unpackdirent(fs:rdslot(sub, 0) or string.rep("\0", 32))
      local dotdot = pack.unpackdirent(fs:rdslot(sub, 1) or string.rep("\0", 32))
      if dot.name ~= ".          " or dot.clus ~= e.clus then
        fail[#fail + 1] = at .. ": . does not point at the directory"
      end
      local pclus = d.clus or 0
      if fs.type == 32 and pclus == fs.rootclus then pclus = 0 end
      if dotdot.name ~= "..         " or dotdot.clus ~= pclus then
        fail[#fail + 1] = ("%s: .. points at cluster %d, parent is %d")
          :format(at, dotdot.clus, pclus)
      end
      walkdir(fs, sub, at, seen, fail, depth + 1)
    end
  end
end

function Fs:check()
  local fail = {}
  local seen = {}

  -- The reserved entries. Entry 0 carries the media byte and entry 1 an
  -- end mark; a driver may put dirty flags in the top bits of entry 1,
  -- so only the low bits are worth asserting on.
  local e0 = self:fatget(0)
  if (e0 & 0xFF) ~= (self.bpb and self.bpb.media or 0xF8) then
    fail[#fail + 1] = ("FAT entry 0 is %x, media byte is %x")
      :format(e0 & 0xFF, self.bpb and self.bpb.media or 0xF8)
  end
  if not self:iseof(self:fatget(1)) then
    fail[#fail + 1] = "FAT entry 1 is not an end mark"
  end

  if self.type == 32 then
    seen[self.rootclus] = "/"
    walkchain(self, self.rootclus, "/", {}, fail, "the root directory")
    local c = self.rootclus
    while self:validclus(c) do
      seen[c] = "/"
      c = self:fatget(c)
    end
  end
  walkdir(self, self:rootdir(), "/", seen, fail, 0)

  -- One sweep of the FAT answers two questions: how much is free, and
  -- what is allocated that the walk above did not reach. The second is
  -- a lost chain -- space that is held and that no name leads to.
  local lost, free = 0, 0
  for c = dat.Clfirst, self.nclus + dat.Clfirst - 1 do
    local v = self:fatget(c)
    if v == dat.Clfree then
      free = free + 1
    elseif not self:isbad(c) and not seen[c] then
      lost = lost + 1
    end
  end
  if lost > 0 then
    fail[#fail + 1] = ("%d clusters are allocated and unreachable")
      :format(lost)
  end

  -- The FAT copies. They are written together on every change, so a
  -- disagreement is either a crash between two sector writes or a
  -- driver that only maintained the first.
  for i = 1, self.numfats - 1 do
    for s = 0, self.fatsz - 1 do
      local a = self:rdsec(self.fatstart + s)
      local b = self:rdsec(self.fatstart + i * self.fatsz + s)
      if a ~= b then
        fail[#fail + 1] = ("FAT copy %d differs at sector %d"):format(i, s)
        break
      end
    end
  end

  if self.freecount and self.freecount ~= free then
    fail[#fail + 1] = ("the free count says %d, the FAT says %d")
      :format(self.freecount, free)
  end

  return fail
end

--------------------------------------------------------------------------
-- repair
--
-- Only one repair is offered, and only when nothing else came back
-- wrong: freeing lost chains. The reason for the condition is the same
-- as gefs's -- what counts as unreachable is only as good as the walk's
-- ability to read every directory, and freeing live clusters because a
-- directory would not parse turns a volume that mostly works into one
-- that does not.

function Fs:fsck(opts)
  opts = opts or {}
  local fail = self:check()
  if not opts.fix then return fail end

  local other = {}
  for _, f in ipairs(fail) do
    if not f:match("allocated and unreachable") then other[#other + 1] = f end
  end
  if #other > 0 then return fail, 0 end

  local seen = {}
  local ignore = {}
  if self.type == 32 then
    local c = self.rootclus
    while self:validclus(c) do seen[c] = "/"; c = self:fatget(c) end
  end
  walkdir(self, self:rootdir(), "/", seen, ignore, 0)

  local freed = 0
  for c = dat.Clfirst, self.nclus + dat.Clfirst - 1 do
    if self:fatget(c) ~= dat.Clfree and not self:isbad(c) and not seen[c] then
      self:fatset(c, dat.Clfree)
      freed = freed + 1
    end
  end
  if freed > 0 then
    self.freecount = self:countfree()
    self.fsidirty = true
  end
  return self:check(), freed
end

return M
