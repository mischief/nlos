-- Files and paths: what a caller of this library actually uses.
--
-- Everything below deals in clusters and slots; this is where they
-- become a path, a length and a string of bytes. The interface is the
-- same shape as gefs's: walk a path, read it, write it, and the object
-- returned by open() is a small handle over an entry.
--
-- One rule from the format shows through and cannot be hidden: a
-- directory has no length of its own. Its size field is zero and its
-- real extent is however many clusters its chain holds, so growing one
-- is allocation and never a length update.

local dat = require "fat.dat"
local pack = require "fat.pack"
local Fs = require "fat.obj"

local M = {}

local rep, sub = string.rep, string.sub

-- The wall clock, if there is one. A machine with no os library and no
-- clock passed in dates what it writes 1980-01-01, which is what a FAT
-- timestamp of zero means and is honest about what the machine knows.
local hostos = rawget(_G, "os")

function Fs:now()
  if self.clock then return self.clock() end
  return hostos and hostos.time() or 0
end

function Fs:writable()
  if self.readonly then error("the volume is read only", 0) end
end

--------------------------------------------------------------------------
-- paths
--
-- Slashes separate, both kinds, since a caller holding a name out of a
-- UEFI path has backslashes in it. An empty component is skipped rather
-- than an error, so "/a//b" and "/a/b" name the same file.

local function split(path)
  local out = {}
  for c in path:gmatch("[^/\\]+") do
    if c == "." then
      -- the current directory, which is where we already are
    elseif c == ".." then
      if #out > 0 then out[#out] = nil end
    else
      out[#out + 1] = c
    end
  end
  return out
end

M.split = split

-- Walk a path to the entry it names. Returns the entry, the directory
-- holding it, and the name within it; for the root, an entry standing
-- in for a directory that has none on disk.
function Fs:walk(path)
  local parts = split(path)
  local d = self:rootdir()
  local ent = {
    name = "/", attr = dat.Adir, size = 0,
    clus = self.type == 32 and self.rootclus or 0,
    root = true,
  }
  for i, name in ipairs(parts) do
    if (ent.attr & dat.Adir) == 0 then
      return nil, ("%s is not a directory"):format(name)
    end
    local e = self:lookup(d, name)
    if not e then
      return nil, ("%s does not exist"):format(path), d,
        (i == #parts) and name or nil
    end
    d = self:dirof(e.clus)
    ent = e
  end
  return ent, d, parts[#parts]
end

-- The directory holding a path, and the last component, whether or not
-- the path exists. This is what create and remove need.
function Fs:walkparent(path)
  local parts = split(path)
  if #parts == 0 then return nil, "the root has no parent" end
  local name = parts[#parts]
  parts[#parts] = nil
  local d = self:rootdir()
  for _, c in ipairs(parts) do
    local e = self:lookup(d, c)
    if not e then return nil, c .. " does not exist" end
    if (e.attr & dat.Adir) == 0 then return nil, c .. " is not a directory" end
    d = self:dirof(e.clus)
  end
  return d, name
end

-- The directory an entry names, for a caller that has one already.
function Fs:dirent(ent)
  return self:dirof(ent.root and 0 or ent.clus)
end

function Fs:stat(path)
  local e, err = self:walk(path)
  if not e then return nil, err end
  return {
    name = e.name,
    size = e.size,
    dir = (e.attr & dat.Adir) ~= 0,
    readonly = (e.attr & dat.Aread) ~= 0,
    hidden = (e.attr & dat.Ahidden) ~= 0,
    system = (e.attr & dat.Asystem) ~= 0,
    archive = (e.attr & dat.Aarchive) ~= 0,
    clus = e.clus,
    mtime = e.mtime,
    ctime = e.ctime,
  }
end

--------------------------------------------------------------------------
-- reading

-- Read count bytes from an entry at an offset. Short reads mean the end
-- of the file and nothing else: a hole is not a thing FAT has, since a
-- cluster is either allocated and holds bytes or the file stops.
function Fs:read(ent, off, count)
  if (ent.attr & dat.Adir) ~= 0 then return nil, "is a directory" end
  if off >= ent.size then return "" end
  if off + count > ent.size then count = ent.size - off end

  local csz = self:clustersz()
  local out = {}
  local c = self:clusat(ent.clus, off // csz)
  local within = off % csz
  local left = count
  while left > 0 do
    if not c then break end        -- the chain is shorter than the size
    local n = csz - within
    if n > left then n = left end
    -- Read whole sectors and cut, rather than reading the run twice:
    -- the cache holds sectors, so the cut is free.
    local s0 = within // self.secsz
    local s1 = (within + n - 1) // self.secsz
    local buf = self:rdsecs(self:clusterlba(c) + s0, s1 - s0 + 1)
    local from = within - s0 * self.secsz
    out[#out + 1] = sub(buf, from + 1, from + n)
    left = left - n
    within = 0
    c = self:fatget(c)
    if not self:validclus(c) then c = nil end
  end
  return table.concat(out)
end

function Fs:readfile(path)
  local e, err = self:walk(path)
  if not e then return nil, err end
  return self:read(e, 0, e.size)
end

--------------------------------------------------------------------------
-- writing
--
-- A write past the end grows the chain first and only then copies, so a
-- volume that runs out of space leaves the file as it was rather than
-- half extended.

local function nclusfor(fs, len)
  local csz = fs:clustersz()
  return (len + csz - 1) // csz
end

function Fs:write(ent, off, s)
  self:writable()
  if (ent.attr & dat.Adir) ~= 0 then return nil, "is a directory" end
  if off + #s > dat.Maxfile then return nil, "file would be too long" end
  if #s == 0 then return 0 end

  local csz = self:clustersz()
  local need = nclusfor(self, off + #s)
  -- How many clusters the file has follows from its length, which
  -- costs nothing to work out; walking the chain to count them would
  -- make writing a large file in pieces quadratic. The chain is only
  -- walked when it turns out to be longer than the length says.
  local have = ent.clus ~= 0 and nclusfor(self, ent.size) or 0
  if have == 0 and ent.clus ~= 0 then have = 1 end
  if need > have and ent.clus ~= 0 then
    local last = self:clusat(ent.clus, have - 1)
    if not last or not self:iseof(self:fatget(last)) then
      have = #self:chain(ent.clus)
    end
  end
  if need > have then
    local last = nil
    if have > 0 then last = self:clusat(ent.clus, have - 1) end
    local got, err = self:allocn(last, need - have)
    if not got then return nil, err end
    if have == 0 then ent.clus = got[1] end
  end

  -- A write that starts past the end makes the bytes between the old
  -- end and it part of the file. FAT has no holes, so they are cleared:
  -- otherwise they are whatever the cluster held for its last owner,
  -- which is somebody else's data.
  if off > ent.size then
    local zero = rep("\0", self.secsz)
    local at = ent.size
    while at < off do
      local ci = at // csz
      local within = at % csz
      local n = math.min(csz - within, off - at)
      local c = self:clusat(ent.clus, ci)
      if not c then break end
      local lba = self:clusterlba(c)
      for si = within // self.secsz, (within + n - 1) // self.secsz do
        local sof = si * self.secsz
        local lo = math.max(within, sof)
        local hi = math.min(within + n, sof + self.secsz)
        if hi - lo == self.secsz then
          self:wrsec(lba + si, zero)
        else
          self:wrat(lba + si, lo - sof, rep("\0", hi - lo))
        end
      end
      at = at + n
    end
  end

  local c = self:clusat(ent.clus, off // csz)
  local within = off % csz
  local pos = 1
  while pos <= #s do
    local n = csz - within
    if n > #s - pos + 1 then n = #s - pos + 1 end
    local lba = self:clusterlba(c)

    -- Whole sectors go straight out. A partial one at either end has to
    -- be read first, since a sector is the smallest thing the device
    -- takes and the rest of it belongs to someone.
    local first = within // self.secsz
    local last = (within + n - 1) // self.secsz
    for si = first, last do
      local sof = si * self.secsz
      local lo = math.max(within, sof)
      local hi = math.min(within + n, sof + self.secsz)
      local piece = sub(s, pos + lo - within, pos + hi - within - 1)
      if hi - lo == self.secsz then
        self:wrsec(lba + si, piece)
      else
        self:wrat(lba + si, lo - sof, piece)
      end
    end

    pos = pos + n
    within = 0
    if pos <= #s then
      c = self:fatget(c)
      if not self:validclus(c) then return nil, "the chain ended early" end
    end
  end

  if off + #s > ent.size then ent.size = off + #s end
  return #s
end

-- Write an entry back to the directory that holds it. Callers that
-- change a file's length or first cluster have to do this, and open()
-- does it at close.
function Fs:flushent(d, ent)
  local now = self:now()
  self:updent(d, ent, {
    clus = ent.clus, size = ent.size,
    wrtdate = pack.packdate(now), wrttime = pack.packtime(now),
    lstaccdate = pack.packdate(now),
    attr = ent.attr | dat.Aarchive,
  })
end

function Fs:writefile(path, s)
  self:writable()
  local e, derr, d, name = self:walk(path)
  local made = false
  if not e then
    if not d or not name then return nil, derr end
    local err
    e, err = self:mkent(d, name, dat.Aarchive, 0, 0)
    if not e then return nil, err end
    made = true
  else
    local perr
    d, perr = self:walkparent(path)
    if not d then return nil, perr end
    if (e.attr & dat.Adir) ~= 0 then return nil, "is a directory" end
    if e.clus ~= 0 then self:free(e.clus) end
    e.clus, e.size = 0, 0
  end
  if #s > 0 then
    local n, err = self:write(e, 0, s)
    if not n then
      -- A write that ran out of space leaves nothing behind: a file
      -- this call created is removed again, and one that existed keeps
      -- the length it now has, which is zero.
      if made then self:delent(d, e) else self:flushent(d, e) end
      return nil, err
    end
  end
  self:flushent(d, e)
  return #s
end

--------------------------------------------------------------------------
-- truncation

function Fs:truncate(path, len)
  self:writable()
  local e, err = self:walk(path)
  if not e then return nil, err end
  if (e.attr & dat.Adir) ~= 0 then return nil, "is a directory" end
  local d, perr = self:walkparent(path)
  if not d then return nil, perr end

  if len > e.size then
    local n, werr = self:write(e, len - 1, "\0")
    if not n then return nil, werr end
  else
    local need = nclusfor(self, len)
    if e.clus ~= 0 then
      if need == 0 then
        self:free(e.clus)
        e.clus = 0
      else
        self:truncchain(e.clus, need)
      end
    end
    e.size = len
  end
  self:flushent(d, e)
  return len
end

--------------------------------------------------------------------------
-- creating and removing

function Fs:create(path, attr)
  self:writable()
  local d, name = self:walkparent(path)
  if not d then return nil, name end
  if self:lookup(d, name) then return nil, path .. " exists" end
  local e, err = self:mkent(d, name, attr or dat.Aarchive, 0, 0)
  if not e then return nil, err end
  return e, d
end

function Fs:createfile(path)
  return self:create(path, dat.Aarchive)
end

function Fs:mkdir(path)
  self:writable()
  local d, name = self:walkparent(path)
  if not d then return nil, name end
  if self:lookup(d, name) then return nil, path .. " exists" end

  local c, err = self:mkdirclus(d)
  if not c then return nil, err end
  local e, eerr = self:mkent(d, name, dat.Adir, c, 0)
  if not e then
    self:free(c)
    return nil, eerr
  end
  return e
end

-- Every component of a path, made if it is not there. A component that
-- exists as a file rather than a directory stops it.
function Fs:mkdirp(path)
  local parts = split(path)
  local at = ""
  for _, c in ipairs(parts) do
    at = at .. "/" .. c
    local e = self:walk(at)
    if not e then
      local ok, err = self:mkdir(at)
      if not ok then return nil, err end
    elseif (e.attr & dat.Adir) == 0 then
      return nil, at .. " is not a directory"
    end
  end
  return true
end

function Fs:remove(path)
  self:writable()
  local e, err = self:walk(path)
  if not e then return nil, err end
  if e.root then return nil, "cannot remove the root" end
  local d, perr = self:walkparent(path)
  if not d then return nil, perr end

  if (e.attr & dat.Adir) ~= 0 and not self:isempty(self:dirof(e.clus)) then
    return nil, path .. " is not empty"
  end
  if e.clus ~= 0 then self:free(e.clus) end
  self:delent(d, e)
  return true
end

--------------------------------------------------------------------------
-- renaming
--
-- Done by writing a new entry and deleting the old one, since a name is
-- part of the entry and there is nothing else to move. The clusters
-- stay where they are, so the cost does not depend on the file's size.

function Fs:rename(from, to)
  self:writable()
  local e, err = self:walk(from)
  if not e then return nil, err end
  if e.root then return nil, "cannot rename the root" end
  local sd = select(1, self:walkparent(from))
  local td, name = self:walkparent(to)
  if not td then return nil, name end

  local old = self:lookup(td, name)
  if old then
    if old.slot == e.slot and old.clus == e.clus then
      return true                       -- renaming onto itself
    end
    return nil, to .. " exists"
  end

  -- A directory moving to a new parent takes its .. with it.
  if (e.attr & dat.Adir) ~= 0 then
    local at = self:dirof(e.clus)
    local pclus = td.clus or 0
    if self.type == 32 and pclus == self.rootclus then pclus = 0 end
    local dotdot = pack.unpackdirent(self:rdslot(at, 1))
    dotdot.clus = pclus
    self:wrslot(at, 1, pack.packdirent(dotdot))
    self:dropindex(at)      -- written straight to the slot
  end

  local new, nerr = self:mkent(td, name, e.attr, e.clus, e.size)
  if not new then return nil, nerr end
  self:delent(sd, e)
  return true
end

--------------------------------------------------------------------------
-- listing

function Fs:ls(path)
  local e, err = self:walk(path or "/")
  if not e then return nil, err end
  if (e.attr & dat.Adir) == 0 then return { e } end
  return self:readdir(self:dirent(e))
end

--------------------------------------------------------------------------
-- an open file
--
-- A handle over an entry and the directory holding it. The entry in
-- memory is the authority while the file is open; close() writes it
-- back, and a handle that is dropped without closing loses the length
-- it grew to but never the clusters, which the FAT already holds.

local File = {}
File.__index = File

function Fs:open(path, mode)
  mode = mode or "r"
  local e, err, d, name = self:walk(path)
  if not e then
    if mode == "r" then return nil, err end
    if not d or not name then return nil, err end
    e, err = self:mkent(d, name, dat.Aarchive, 0, 0)
    if not e then return nil, err end
  else
    if (e.attr & dat.Adir) ~= 0 then return nil, "is a directory" end
    local perr
    d, perr = self:walkparent(path)
    if not d then return nil, perr end
    if mode == "w" then
      if e.clus ~= 0 then self:free(e.clus) end
      e.clus, e.size = 0, 0
    end
  end
  local f = setmetatable({ fs = self, d = d, e = e, off = 0 }, File)
  if mode == "a" then f.off = e.size end
  return f
end

function File:read(n)
  if n == nil then n = self.e.size - self.off end
  local s, err = self.fs:read(self.e, self.off, n)
  if not s then return nil, err end
  self.off = self.off + #s
  return s
end

function File:write(s)
  local n, err = self.fs:write(self.e, self.off, s)
  if not n then return nil, err end
  self.off = self.off + n
  self.dirty = true
  return n
end

function File:seek(off)
  self.off = off
  return off
end

function File:length() return self.e.size end

function File:close()
  if self.dirty then self.fs:flushent(self.d, self.e) end
  self.e, self.d = nil, nil
end

M.File = File
return M
