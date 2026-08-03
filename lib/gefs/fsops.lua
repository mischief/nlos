-- File semantics: gefs's fs.c, minus the 9P.
--
-- Three key spaces make a filesystem out of a sorted map. A dirent is
-- Kent{parent qid, name}, so every entry of a directory is one
-- contiguous range and a listing is a prefix scan. A file's contents are
-- Kdat{qid, block offset} pointing at raw blocks, so a file is also a
-- contiguous range and reading it is sequential. And Kup{qid} names a
-- directory's parent, which is what makes walking to ".." a lookup
-- rather than a search.
--
-- A mount is a label plus the tree it currently names. Writing through a
-- mutable label moves it; writing through anything else is refused.

local dat = require "gefs.dat"
local pack = require "gefs.pack"
local Fs = require "gefs.obj"

local M = {}

local Mount = {}
Mount.__index = Mount

local File = {}
File.__index = File

M.Mount, M.File = Mount, File

--------------------------------------------------------------------------
-- mounting

function Fs:mount(name)
  for _, m in ipairs(self.mounts) do
    if m.name == name then return m end
  end
  local t, flg = self:opensnap(name)
  if t == nil then error("no such snapshot: " .. name, 0) end
  local m = setmetatable({
    fs = self, name = name, root = t, flag = flg,
  }, Mount)
  self.mounts[#self.mounts + 1] = m
  return m
end

function Fs:umount(m)
  for i, mm in ipairs(self.mounts) do
    if mm == m then table.remove(self.mounts, i); break end
  end
  self:closesnap(m.root)
end

-- a timestamp in nanoseconds. clockfn is how a host without os.time (the
-- freestanding kernel has none) supplies one; where os is present it is
-- the default, and a volume with neither still gets a valid zero rather
-- than a crash on the first create.
function Fs:now()
  if self.clockfn then return self.clockfn() end
  if os and os.time then return os.time() * dat.Nsec end
  return 0
end

function Mount:writable()
  if self.fs.rdonly then error("filesystem is read only", 0) end
  if self.flag & dat.Lmut == 0 then
    error("snapshot is not writable: " .. self.name, 0)
  end
end

function Mount:upsert(msgs)
  self:writable()
  self.fs:btupsert(self.root, msgs)
  self.fs.snap.dirty = true
end

--------------------------------------------------------------------------
-- walking

-- One step: the dirent named by (parent qid, name), or nil.
function Mount:walk1(up, name)
  local kv = self.fs:btlookup(self.root, pack.packdkey(up, name))
  if kv == nil then return nil end
  local d = pack.kv2dir(kv.k, kv.v)
  -- the parent qid is in the key, not the value, so it has to be put
  -- back for anything that later wants to rewrite this entry
  d.up = up
  return d, kv.k
end

-- A directory's own dirent, found from its qid alone. Kup{qid} holds
-- that directory's (parent qid, name), which is exactly the Kent key
-- that names it -- so one lookup turns a qid into an entry without
-- knowing the path that reached it.
function Mount:direntof(qpath)
  local kv = self.fs:btlookup(self.root, pack.packsuper(qpath))
  if kv == nil then return nil end
  local up, name = pack.unpackdkey(kv.v)
  return self:walk1(up, name)
end

-- The parent of a directory. Two steps, because Kup names the directory
-- itself rather than its parent: the first gives the parent's qid and
-- the second gives the parent's entry. Nil at the root, which has no
-- parent to find.
function Mount:parent(qpath)
  local kv = self.fs:btlookup(self.root, pack.packsuper(qpath))
  if kv == nil then return nil end
  local up = pack.unpackdkey(kv.v)
  if up == -1 then return nil end
  return self:direntof(up)
end

local function split(path)
  local out = {}
  for e in path:gmatch("[^/]+") do
    if e ~= "." then out[#out + 1] = e end
  end
  return out
end

M.split = split

-- Resolve a whole path. Returns the dirent, or nil and the element that
-- could not be walked, so callers can tell "no such directory" from "no
-- such file".
function Mount:walk(path)
  local d = self:walk1(-1, "")
  if d == nil then return nil, "no root dirent" end
  for _, e in ipairs(split(path)) do
    if d.mode & dat.DMDIR == 0 then return nil, "not a directory" end
    if e == ".." then
      local p = self:parent(d.qid.path)
      d = p or d
    else
      d = self:walk1(d.qid.path, e)
      if d == nil then return nil, "does not exist: " .. e end
    end
  end
  return d
end

function Mount:stat(path)
  local d, err = self:walk(path)
  if d == nil then return nil, err end
  return d
end

--------------------------------------------------------------------------
-- reading
--
-- A hole reads as zeroes: a Kdat key that is not in the tree is a block
-- that was never written, which is what makes a sparse file cost only
-- the keys it does have.

function Mount:readblk(qpath, off, n, len)
  local blksz = self.fs.geom.blksz
  if off >= len then return "" end

  local fb = off & ~(blksz - 1)
  local fo = off & (blksz - 1)
  if fo + n > blksz then n = blksz - fo end

  local kv = self.fs:btlookup(self.root, pack.packdatkey(qpath, fb))
  if kv == nil then return string.rep("\0", n) end

  local b = self.fs:getblk(pack.unpackbp(kv.v), require("gefs.blk").GBraw)
  return b.data:sub(fo + 1, fo + n)
end

function Mount:read(d, off, count)
  if d.mode & dat.DMDIR ~= 0 then error("cannot read a directory", 0) end
  if off < 0 then error("negative offset", 0) end
  if off > d.length then return "" end
  local c = count
  if off + c > d.length then c = d.length - off end

  local out = {}
  while c > 0 do
    local s = self:readblk(d.qid.path, off, c, d.length)
    if #s == 0 then break end
    out[#out + 1] = s
    off = off + #s
    c = c - #s
  end
  return table.concat(out)
end

function Mount:readfile(path)
  local d, err = self:walk(path)
  if d == nil then return nil, err end
  return self:read(d, 0, d.length)
end

--------------------------------------------------------------------------
-- writing

-- Build the message that replaces one block. A partial write over an
-- existing block reads it first; a partial write over a hole zero-fills
-- the rest, so a block is always whole once it exists.
function Mount:writeblk(qpath, s, spos, off, n, len)
  local fs = self.fs
  local blksz = fs.geom.blksz
  local fb = off & ~(blksz - 1)
  local fo = off & (blksz - 1)
  if fo + n > blksz then n = blksz - fo end
  -- a write that reaches the end of its block is part of a run, so ask
  -- the allocator for the low end of a range and keep the file together
  local seq = (fo + n >= blksz)

  local k = pack.packdatkey(qpath, fb)
  local b = fs:newdblk(self.root, qpath, seq)

  local old
  if fb < len and (fo ~= 0 or n ~= blksz) then
    local kv = fs:btlookup(self.root, k)
    if kv ~= nil then
      old = fs:getblk(pack.unpackbp(kv.v), require("gefs.blk").GBraw).data
    end
  end

  local body = s:sub(spos, spos + n - 1)
  if old ~= nil then
    b.data = old:sub(1, fo) .. body .. old:sub(fo + n + 1)
  else
    b.data = string.rep("\0", fo) .. body
      .. string.rep("\0", blksz - fo - n)
  end
  assert(#b.data == blksz)

  fs:enqueue(b)
  return { op = dat.Oinsert, k = k, v = pack.packbp(b.bp) }, n
end

-- The wstat that follows a write: the length if it grew, and always the
-- modification time and the last writer.
local function wstatbuf(fields)
  local flag = 0
  local parts = {}
  local function add(bit, fmt, v)
    flag = flag | bit
    parts[#parts + 1] = string.pack(fmt, v)
  end
  if fields.length then add(dat.Owsize, ">i8", fields.length) end
  if fields.mode then add(dat.Owmode, ">I4", fields.mode) end
  if fields.mtime then add(dat.Owmtime, ">i8", fields.mtime) end
  if fields.atime then add(dat.Owatime, ">i8", fields.atime) end
  if fields.uid then add(dat.Owuid, ">i4", fields.uid) end
  if fields.gid then add(dat.Owgid, ">i4", fields.gid) end
  if fields.muid then add(dat.Owmuid, ">i4", fields.muid) end
  return string.pack(">I1", flag) .. table.concat(parts)
end

M.wstatbuf = wstatbuf

-- Blocks per upsert. Any number works -- a batch that cannot be absorbed
-- in one pass is retried by btupsert -- but a bound keeps the message
-- array and the blocks it pins to a fixed size however big the write is.
local CHUNK = 32

function Mount:write(d, off, s, uid)
  self:writable()
  if d.mode & dat.DMDIR ~= 0 then error("cannot write a directory", 0) end
  if off < 0 then error("negative offset", 0) end
  if d.mode & dat.DMAPPEND ~= 0 then off = d.length end

  local fs = self.fs
  local key = pack.packdkey(d.up, d.name)
  local written = 0
  local pos = 1
  local c = #s
  local o = off

  while c > 0 do
    local mb = {}
    -- the length as it was when this batch started: it decides whether
    -- a partially written block already exists to read around
    local len = d.length
    while c > 0 and #mb < CHUNK do
      local m, n = self:writeblk(d.qid.path, s, pos, o, c, len)
      mb[#mb + 1] = m
      pos = pos + n
      o = o + n
      c = c - n
      written = written + n
    end
    local fields = { mtime = fs:now(), muid = uid or d.muid }
    if o > d.length then
      d.length = o
      fields.length = o
    end
    mb[#mb + 1] = { op = dat.Owstat, k = key, v = wstatbuf(fields) }
    self:upsert(mb)
    d.qid.vers = (d.qid.vers + 1) & 0xffffffff
  end

  if written == 0 then
    local fields = { mtime = fs:now(), muid = uid or d.muid }
    self:upsert({ { op = dat.Owstat, k = key, v = wstatbuf(fields) } })
    d.qid.vers = (d.qid.vers + 1) & 0xffffffff
  end
  return written
end

function Mount:writefile(path, s)
  local d, err = self:walk(path)
  if d == nil then return nil, err end
  self:truncate(d, 0)
  return self:write(d, 0, s)
end

--------------------------------------------------------------------------
-- truncation
--
-- Every block wholly past the new end is cleared. The block the new end
-- falls inside is kept but its tail is zeroed: without that, growing the
-- file again would expose whatever used to be there, since a write that
-- starts past the end still reads the old block to fill around itself.
--
-- Upstream starts this walk at the unaligned length and steps by the
-- block size, so it clears nothing at all unless the new length happens
-- to be aligned. Rounding up is the same intent with the arithmetic
-- fixed, and changes nothing on disk.

function Mount:truncate(d, len)
  self:writable()
  local fs = self.fs
  local blksz = fs.geom.blksz
  local old = d.length
  local mb = {}

  if len < old then
    local first = (len + blksz - 1) & ~(blksz - 1)
    local off = first
    while off < old do
      mb[#mb + 1] = {
        op = dat.Oclearb, k = pack.packdatkey(d.qid.path, off), v = "",
      }
      if #mb >= CHUNK then
        self:upsert(mb)
        mb = {}
      end
      off = off + blksz
    end

    local fo = len & (blksz - 1)
    if fo ~= 0 then
      local fb = len & ~(blksz - 1)
      local k = pack.packdatkey(d.qid.path, fb)
      local kv = fs:btlookup(self.root, k)
      if kv ~= nil then
        local was = fs:getblk(pack.unpackbp(kv.v),
          require("gefs.blk").GBraw).data
        local b = fs:newdblk(self.root, d.qid.path, false)
        b.data = was:sub(1, fo) .. string.rep("\0", blksz - fo)
        fs:enqueue(b)
        mb[#mb + 1] = { op = dat.Oinsert, k = k, v = pack.packbp(b.bp) }
      end
    end
  end

  d.length = len
  mb[#mb + 1] = {
    op = dat.Owstat,
    k = pack.packdkey(d.up, d.name),
    v = wstatbuf({ length = len, mtime = fs:now() }),
  }
  self:upsert(mb)
  d.qid.vers = (d.qid.vers + 1) & 0xffffffff
end

--------------------------------------------------------------------------
-- creating and removing

local function okname(name)
  if name == "" then return "empty file name" end
  if name == "." or name == ".." then return "reserved name: " .. name end
  if #name > dat.Maxname then return "name too long" end
  if name:find("/") then return "name contains a slash" end
  for i = 1, #name do
    if name:byte(i) < 0x20 then return "name contains a control character" end
  end
  return nil
end

M.okname = okname

function Mount:create(dir, name, perm, uid, gid)
  self:writable()
  local err = okname(name)
  if err ~= nil then error(err, 0) end
  if dir.mode & dat.DMDIR == 0 then error("not a directory", 0) end
  if perm & (dat.DMMOUNT | dat.DMAUTH) ~= 0 then error("bad permissions", 0) end
  if self:walk1(dir.qid.path, name) ~= nil then
    error("already exists: " .. name, 0)
  end

  local fs = self.fs
  -- the top bit marks a qid the filesystem serves itself, so running
  -- into it is running out of qids. Tested as a bit rather than a
  -- comparison because Lua's integers are signed and that bit is the
  -- sign.
  if fs.nextqid & dat.Qmagic ~= 0 then error("out of qids", 0) end

  local qtype = 0
  if perm & dat.DMDIR ~= 0 then qtype = qtype | dat.QTDIR end
  if perm & dat.DMAPPEND ~= 0 then qtype = qtype | dat.QTAPPEND end
  if perm & dat.DMEXCL ~= 0 then qtype = qtype | dat.QTEXCL end
  if perm & dat.DMTMP ~= 0 then qtype = qtype | dat.QTTMP end

  local mode = perm
  if perm & dat.DMDIR ~= 0 then
    mode = mode & (~0x1ff | (dir.mode & 0x1ff))
  else
    mode = mode & (~0x1b6 | (dir.mode & 0x1b6))
  end

  local now = fs:now()
  local d = {
    flag = 0,
    qid = { path = fs.nextqid, vers = 0, type = qtype },
    mode = mode & 0xffffffff,
    atime = now, mtime = now, length = 0,
    uid = uid or dir.uid, gid = gid or dir.gid, muid = uid or dir.uid,
    name = name, up = dir.qid.path,
  }
  fs.nextqid = fs.nextqid + 1

  local mb = {}
  local k, v = pack.dir2kv(dir.qid.path, d)
  mb[#mb + 1] = { op = dat.Oinsert, k = k, v = v }
  if perm & dat.DMDIR ~= 0 then
    mb[#mb + 1] = {
      op = dat.Oinsert,
      k = pack.packsuper(d.qid.path),
      v = pack.packdkey(dir.qid.path, name),
    }
  end
  -- touch the parent: a zero-flag wstat, which bumps its version and
  -- nothing else
  mb[#mb + 1] = {
    op = dat.Owstat,
    k = pack.packdkey(dir.up or -1, dir.name),
    v = "\0",
  }
  self:upsert(mb)
  dir.qid.vers = (dir.qid.vers + 1) & 0xffffffff
  return d
end

function Mount:mkdir(path, perm, uid, gid)
  local dir, base = path:match("^(.*)/([^/]+)$")
  if dir == nil then dir, base = "", path end
  local pd, err = self:walk(dir == "" and "/" or dir)
  if pd == nil then return nil, err end
  return self:create(pd, base, dat.DMDIR | (perm or 0x1ff), uid, gid)
end

function Mount:createfile(path, perm, uid, gid)
  local dir, base = path:match("^(.*)/([^/]+)$")
  if dir == nil then dir, base = "", path end
  local pd, err = self:walk(dir == "" and "/" or dir)
  if pd == nil then return nil, err end
  return self:create(pd, base, perm or 0x1b6, uid, gid)
end

-- A directory has to be empty, which is a scan that stops at the first
-- entry rather than a count.
function Mount:isempty(qpath)
  local s = self.fs:btscan(self.root, pack.packdkey(qpath, nil))
  local kv = s:next()
  s:close()
  return kv == nil
end

function Mount:remove(d)
  self:writable()
  if d.up == nil then error("cannot remove the root", 0) end
  if d.qid.path & dat.Qmagic ~= 0 then error("no permission", 0) end
  if self.fs:btlookup(self.root, pack.packdkey(d.up, d.name)) == nil then
    error("does not exist: " .. d.name, 0)
  end
  if d.mode & dat.DMDIR ~= 0 and not self:isempty(d.qid.path) then
    error("directory is not empty: " .. d.name, 0)
  end

  local mb = {
    { op = dat.Odelete, k = pack.packdkey(d.up, d.name), v = "" },
  }
  if d.mode & dat.DMDIR ~= 0 then
    mb[#mb + 1] = {
      op = dat.Oclobber, k = pack.packsuper(d.qid.path), v = "",
    }
    self:upsert(mb)
  else
    -- The dirent goes in the same batch as the first blocks so the file
    -- is gone at once; the rest of its blocks follow, which is what
    -- upstream hands to a sweeper.
    local blksz = self.fs.geom.blksz
    local off = 0
    while off < d.length do
      mb[#mb + 1] = {
        op = dat.Oclearb, k = pack.packdatkey(d.qid.path, off), v = "",
      }
      if #mb >= CHUNK then
        self:upsert(mb)
        mb = {}
      end
      off = off + blksz
    end
    if #mb > 0 then self:upsert(mb) end
  end
end

function Mount:removepath(path)
  local d, err = self:walk(path)
  if d == nil then return nil, err end
  self:remove(d)
  return true
end

--------------------------------------------------------------------------
-- wstat

function Mount:wstat(d, changes)
  self:writable()
  local fs = self.fs
  local mb = {}
  local key = pack.packdkey(d.up, d.name)

  if changes.length ~= nil and changes.length < d.length then
    self:truncate(d, changes.length)
    local rest = {}
    for k, v in pairs(changes) do
      if k ~= "length" then rest[k] = v end
    end
    changes = rest
  end

  if changes.name ~= nil and changes.name ~= d.name then
    local err = okname(changes.name)
    if err ~= nil then error(err, 0) end
    if self:walk1(d.up, changes.name) ~= nil then
      error("already exists: " .. changes.name, 0)
    end
    -- a rename is a delete and an insert, because the name is the key
    local nd = {}
    for k, v in pairs(d) do nd[k] = v end
    nd.name = changes.name
    nd.qid = { path = d.qid.path, vers = d.qid.vers + 1, type = d.qid.type }
    if changes.mode ~= nil then
      nd.mode = changes.mode
      nd.qid.type = changes.mode >> 24
    end
    if changes.length ~= nil then nd.length = changes.length end
    if changes.mtime ~= nil then nd.mtime = changes.mtime end
    if changes.atime ~= nil then nd.atime = changes.atime end
    if changes.uid ~= nil then nd.uid = changes.uid end
    if changes.gid ~= nil then nd.gid = changes.gid end
    if changes.muid ~= nil then nd.muid = changes.muid end

    local nk, nv = pack.dir2kv(d.up, nd)
    mb[#mb + 1] = { op = dat.Odelete, k = key, v = "" }
    mb[#mb + 1] = { op = dat.Oinsert, k = nk, v = nv }
    if d.mode & dat.DMDIR ~= 0 then
      mb[#mb + 1] = {
        op = dat.Oinsert,
        k = pack.packsuper(d.qid.path),
        v = pack.packdkey(d.up, nd.name),
      }
    end
    self:upsert(mb)
    for k, v in pairs(nd) do d[k] = v end
    return d
  end

  local fields = {}
  if changes.length ~= nil then fields.length = changes.length end
  if changes.mode ~= nil then fields.mode = changes.mode & 0xffffffff end
  if changes.mtime ~= nil then fields.mtime = changes.mtime end
  if changes.atime ~= nil then fields.atime = changes.atime end
  if changes.uid ~= nil then fields.uid = changes.uid end
  if changes.gid ~= nil then fields.gid = changes.gid end
  if changes.muid ~= nil then fields.muid = changes.muid end
  if next(fields) == nil then return d end

  mb[#mb + 1] = { op = dat.Owstat, k = key, v = wstatbuf(fields) }
  self:upsert(mb)

  if fields.length then d.length = fields.length end
  if fields.mode then d.mode = fields.mode; d.qid.type = fields.mode >> 24 end
  if fields.mtime then d.mtime = fields.mtime end
  if fields.atime then d.atime = fields.atime end
  if fields.uid then d.uid = fields.uid end
  if fields.gid then d.gid = fields.gid end
  if fields.muid then d.muid = fields.muid end
  d.qid.vers = (d.qid.vers + 1) & 0xffffffff
  return d
end

--------------------------------------------------------------------------
-- listing

function Mount:readdir(d)
  if d.mode & dat.DMDIR == 0 then error("not a directory", 0) end
  local out = {}
  local s = self.fs:btscan(self.root, pack.packdkey(d.qid.path, nil))
  for kv in s:iter() do
    local e = pack.kv2dir(kv.k, kv.v)
    e.up = d.qid.path
    out[#out + 1] = e
  end
  s:close()
  return out
end

function Mount:ls(path)
  local d, err = self:walk(path or "/")
  if d == nil then return nil, err end
  return self:readdir(d)
end

--------------------------------------------------------------------------
-- an open file, for callers that would rather not carry an offset

function Mount:open(path, mode)
  local d, err = self:walk(path)
  if d == nil then return nil, err end
  return setmetatable({ mnt = self, d = d, off = 0, mode = mode or "r" }, File)
end

function File:read(n)
  local s = self.mnt:read(self.d, self.off, n or self.d.length - self.off)
  self.off = self.off + #s
  return s
end

function File:write(s)
  local n = self.mnt:write(self.d, self.off, s)
  self.off = self.off + n
  return n
end

function File:seek(off) self.off = off; return off end
function File:length() return self.d.length end
function File:close() self.d = nil end

return M
