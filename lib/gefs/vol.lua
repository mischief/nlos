-- Making a volume and opening one: gefs's ream.c and load.c.
--
-- A volume is a superblock at offset zero, a run of arenas, and a backup
-- superblock in the last whole block. Each arena keeps two copies of its
-- header, one at each end of its own span, so a torn write to one leaves
-- the other; load takes whichever verifies.
--
-- Nothing here knows about files. What ream() plants is three trees --
-- an empty one, the administrative one, and the main one -- and the
-- snapshot tree that names them.

local dat = require "gefs.dat"
local blk = require "gefs.blk"
local pack = require "gefs.pack"
local store = require "gefs.store"
local Fs = require "gefs.obj"

require "gefs.tree"
require "gefs.snap"

local M = {}

local spack = string.pack

--------------------------------------------------------------------------
-- the object

local function newfs(dev, geom, opts)
  opts = opts or {}
  local fs = setmetatable({
    dev = dev,
    geom = geom,
    clockfn = opts.clockfn,
    cache = {}, ccount = 0, clock = 0,
    cmax = opts.cachesz or 512,
    nwrite = 0, nread = 0,
    narena = 0, arenas = {}, arenabp = {},
    roundrobin = 0, usereserve = false,
    nextqid = dat.Nreamqid, nextgen = 0, qgen = 0, flag = 0,
    snap = {
      ht = 1, bp = dat.zb(), memgen = 0, gen = -1,
      base = -1, pred = -1, succ = -1, nref = 0, nlbl = 0,
      flag = 0, dirty = false,
    },
    snapdl = { gen = -1, bgen = -1, hd = dat.zb(), tl = dat.zb(), ins = nil },
    dropdl = { gen = -1, bgen = -1, hd = dat.zb(), tl = dat.zb(), ins = nil },
    dlcache = {}, dlorder = {}, dlcount = 0, dlcmax = opts.dlcachesz or 1024,
    mounts = {},
    rdonly = false,
    users = nil,
  }, Fs)
  return fs
end

M.newfs = newfs

--------------------------------------------------------------------------
-- arenas

local function initarena(fs, a, hdaddr, asz)
  local blksz = fs.geom.blksz
  local addr = hdaddr + 2 * blksz  -- leave room for the two headers

  local b = blk.new(dat.Tlog, addr, -1)
  b.logp = dat.zb()
  b.logents = {
    spack(">i8", addr | dat.LogFree), spack(">i8", asz - 2 * blksz),
    spack(">i8", addr | dat.LogAlloc), spack(">i8", blksz),
    spack(">i8", dat.LogSync),
  }
  b.logsz = 8 * #b.logents
  fs:writeblk(b)

  a.loghd = { addr = b.bp.addr, hash = -1, gen = -1 }
  a.size = asz
  a.used = blksz
  a.base = hdaddr
  a.free = {}
  a.nlog = 0
  a.lastlogsz = 0
  a.logtl = nil

  local hdr = { loghd = a.loghd, size = a.size, used = a.used }
  local h0 = blk.new(dat.Tarena, hdaddr, -1)
  h0.arena = hdr
  fs:writeblk(h0)
  local h1 = blk.new(dat.Tarena, hdaddr + blksz, -1)
  h1.arena = hdr
  fs:writeblk(h1)
  a.h0, a.h1 = h0, h1
end

-- Load one arena's header. Either copy will do; if neither verifies the
-- volume is beyond help, and if only one does the other is still read
-- unchecked so there is something to overwrite at the next sync.
function Fs:loadarena(a, hd)
  local blksz = self.geom.blksz
  -- The footer verifies against the header's hash, and that is not a
  -- shortcut: the two hold identical bytes, and a block hash covers the
  -- contents and not the address. One recorded hash checks both copies.
  local tl = { addr = hd.addr + blksz, hash = hd.hash, gen = -1 }

  local h0 = self:tryblk(hd, 0)
  local h1 = self:tryblk(tl, 0)
  local good = h0 or h1
  if good == nil then
    error(("arena at %d has no usable header"):format(hd.addr), 0)
  end
  if h0 == nil then h0 = self:getblk(hd, blk.GBnochk) end
  if h1 == nil then h1 = self:getblk(tl, blk.GBnochk) end

  local hdr = good.arena
  a.loghd = hdr.loghd
  a.size = hdr.size
  a.used = hdr.size
  a.base = hd.addr
  a.free = {}
  a.nlog = 0
  a.lastlogsz = 0
  a.logtl = nil
  a.h0, a.h1 = h0, h1
  a.reserve = a.size // 1024
  if a.reserve < 512 * dat.KiB then a.reserve = 512 * dat.KiB end
  if a.reserve > 8 * dat.MiB then a.reserve = 8 * dat.MiB end
end

--------------------------------------------------------------------------
-- what ream plants

local function initroot(fs, r)
  -- values go in in key order, because setval appends
  local d = pack.fillxdir(dat.Qmainroot, "", dat.QTDIR, dat.DMDIR | 0x1fd, 0)
  local k, v = pack.dir2kv(-1, d)
  r:setval({ k = k, v = v }, fs.geom)
  r:setval({ k = pack.packsuper(dat.Qmainroot), v = pack.packdkey(-1, "") },
    fs.geom)
end

local function initadm(fs, r, u, nu)
  r:setval({
    k = pack.packdatkey(dat.Qadmuser, 0),
    v = pack.packbp(u.bp),
  }, fs.geom)

  -- sorted by name length and then alphabetically, which is what the
  -- two-byte length prefix in front of a name does to the key order
  local function ent(qid, name, qtype, mode, len)
    local d = pack.fillxdir(qid, name, qtype, mode, len)
    local k, v = pack.dir2kv(dat.Qadmroot, d)
    r:setval({ k = k, v = v }, fs.geom)
  end
  ent(dat.Qctl, "ctl", dat.QTFILE, 0x1b4, 0)
  ent(dat.Qadmuser, "users", dat.QTFILE, 0x1b4, nu)
  ent(dat.Qstatus, "status", dat.QTFILE, 0x1b4, 0)

  local d = pack.fillxdir(dat.Qadmroot, "", dat.QTDIR, dat.DMDIR | 0x1fd, 0)
  local k, v = pack.dir2kv(-1, d)
  r:setval({ k = k, v = v }, fs.geom)
  r:setval({ k = pack.packsuper(dat.Qadmroot), v = pack.packdkey(-1, "") },
    fs.geom)
end

local function initsnap(fs, s, r, a)
  local function lbl(name, gen, flg)
    local k, v = pack.lbl2kv(name, gen, flg)
    s:setval({ k = k, v = v }, fs.geom)
  end
  lbl("adm", 1, dat.Lmut)
  lbl("empty", 0, 0)
  lbl("main", 2, dat.Lmut)

  local function tree(t)
    local k, v = pack.tree2kv(t)
    s:setval({ k = k, v = v }, fs.geom)
  end

  -- 'empty' is the base every other tree forks from, so it starts with
  -- the two references that adm and main hold on it
  tree({ flag = 0, nref = 2, nlbl = 1, ht = 1, gen = fs.nextgen,
         base = -1, pred = -1, succ = -1, bp = r.bp })
  fs.nextgen = fs.nextgen + 1
  tree({ flag = 0, nref = 0, nlbl = 1, ht = 1, gen = fs.nextgen,
         base = 0, pred = -1, succ = -1, bp = a.bp })
  fs.nextgen = fs.nextgen + 1
  tree({ flag = 0, nref = 0, nlbl = 1, ht = 1, gen = fs.nextgen,
         base = 0, pred = -1, succ = -1, bp = r.bp })
  fs.nextgen = fs.nextgen + 1
end

--------------------------------------------------------------------------
-- ream

function M.ream(dev, opts)
  opts = opts or {}
  local user = opts.user or "glenda"
  local geom = dat.geom(opts.blksz, opts.bufspc)
  local blksz = geom.blksz
  local fs = newfs(dev, geom, opts)

  local sz = dev:size()
  if sz < 16 * dat.MiB + blksz then
    error("ream: disk too small", 0)
  end
  sz = sz - sz % blksz - 2 * blksz

  -- one arena per 4TiB, and never fewer than 8: arenas are what let
  -- allocation spread out, and 8 is enough for that on any disk
  local narena = (sz + 4096 * dat.GiB - 1) // (4096 * dat.GiB)
  if narena < 8 then narena = 8 end
  if narena >= 32 then narena = 32 end

  local asz = sz // narena
  asz = asz - (asz % blksz) - 2 * blksz
  if asz <= 4 * blksz then
    error("ream: disk too small for " .. narena .. " arenas", 0)
  end

  fs.narena = narena
  fs.usereserve = true
  fs.sb0 = blk.new(dat.Tsuper, 0, -1)
  fs.sb1 = blk.new(dat.Tsuper, sz + blksz, -1)

  local off = blksz
  for i = 1, narena do
    local a = {}
    fs.arenas[i] = a
    initarena(fs, a, off, asz)
    fs.arenabp[i] = a.h0.bp
    off = off + asz + 2 * blksz
  end
  for i = 1, narena do
    local a = fs.arenas[i]
    fs:loadarena(a, a.h0.bp)
    fs:loadlog(a, a.loghd)
  end

  local main = { root = { ht = 1, bp = dat.zb(), memgen = 0, base = -1 } }
  local adm = { root = { ht = 1, bp = dat.zb(), memgen = 0, base = -1 } }

  local mb = fs:newblk(main.root, dat.Tleaf)
  initroot(fs, mb)
  fs:writeblk(mb)
  main.root.ht = 1
  main.root.bp = mb.bp

  local ab = fs:newblk(adm.root, dat.Tleaf)
  local ub = fs:newdblk(adm.root, 0, true)
  local utab = ("-1:adm::%s\n0:none::\n1:%s:%s:\n"):format(user, user, user)
  ub.data = utab .. string.rep("\0", blksz - #utab)
  fs:writeblk(ub)
  initadm(fs, ab, ub, #utab)
  fs:writeblk(ab)
  adm.root.ht = 1
  adm.root.bp = ab.bp

  -- a snapshot tree with the three trees in it, which is the initial
  -- state a mount reads back
  local tb = fs:newblk(main.root, dat.Tleaf)
  initsnap(fs, tb, mb, ab)
  fs:writeblk(tb)

  fs.snap.bp = tb.bp
  fs.snap.ht = 1
  fs.snapdl.hd = dat.zb()
  fs.snapdl.tl = dat.zb()
  fs.nextqid = dat.Nreamqid

  for i = 1, narena do
    local a = fs.arenas[i]
    fs:flushlog(a)
    a.h0.arena = { loghd = a.loghd, size = a.size, used = a.used }
    a.h1.arena = a.h0.arena
    fs:finalize(a.h0)
    fs:finalize(a.h1)
    fs:writeblk(a.h0)
    fs:writeblk(a.h1)
    fs.arenabp[i] = { addr = a.h0.bp.addr, hash = a.h0.bp.hash, gen = -1 }
  end

  local sb = pack.packsb({
    bufspc = geom.bufspc, narena = narena,
    snap = fs.snap, snapdl = fs.snapdl,
    flag = fs.flag, nextqid = fs.nextqid,
    nextgen = fs.nextgen, qgen = fs.qgen,
    arenabp = fs.arenabp,
  }, blksz)
  sb = sb .. string.rep("\0", blksz - #sb)
  fs.sb0.data = sb
  fs.sb1.data = sb
  fs:writeblk(fs.sb0)
  fs:writeblk(fs.sb1)
  fs:devsync()
  fs.usereserve = false
  return fs
end

--------------------------------------------------------------------------
-- grow
--
-- Adding arenas to a volume whose device got bigger. This is 9front's
-- growfs, except that it runs on a mounted volume rather than as a
-- separate command, which it can because growing is purely additive: no
-- block moves, no pointer is rewritten, and nothing existing is read.
--
-- The whole thing turns on one ordering. New arenas are invisible until
-- narena says they exist, and narena only reaches disk in the superblock
-- that sync() writes last. So a crash anywhere before that leaves the
-- volume exactly as it was, with some initialised headers sitting in
-- space no allocator will ever look at, and running grow again is safe.

-- The superblock names every arena and must stay one block. Ask the
-- packer rather than counting bytes here, so a format change cannot make
-- this silently wrong.
local function sbfits(fs, narena, blksz)
  local bps = {}
  for i = 1, narena do bps[i] = fs.arenabp[i] or dat.zb() end
  local s = pack.packsb({
    bufspc = fs.geom.bufspc, narena = narena,
    snap = fs.snap, snapdl = fs.snapdl,
    flag = fs.flag, nextqid = fs.nextqid,
    nextgen = fs.nextgen, qgen = fs.qgen,
    arenabp = bps,
  }, blksz)
  return #s <= blksz
end

-- Returns how many arenas were added, and how many bytes they hold.
function Fs:grow(opts)
  opts = opts or {}
  if self.rdonly then error("grow: filesystem is read only", 0) end
  local blksz = self.geom.blksz
  local nnew = opts.narena or 4
  if nnew < 1 then error("grow: asked for no arenas", 0) end

  local sz = self.dev:size()
  local last = self.arenas[self.narena]
  local off = last.base + last.size + 2 * blksz

  local eb = sz - sz % blksz - blksz    -- where the backup goes now

  -- Step over the backup superblock rather than through it: until the
  -- commit at the end of this function lands, that block is still the
  -- volume's second chance, and one block is a cheap price for keeping
  -- it whole. Only when it is in the way, though -- a volume opened
  -- after the device grew already has its backup out at the new end,
  -- and treating that as the floor would leave nowhere to build.
  if self.sb1.bp.addr >= off and self.sb1.bp.addr < eb then
    off = self.sb1.bp.addr + blksz
  end

  local avail = eb - off
  if avail <= 0 then error("grow: the device has no room to grow into", 0) end

  local asz = avail // nnew
  asz = asz - (asz % blksz) - 2 * blksz
  if asz <= 4 * blksz then
    error(("grow: %d bytes is too little for %d arenas"):format(avail, nnew), 0)
  end
  if not sbfits(self, self.narena + nnew, blksz) then
    error(("grow: %d arenas will not fit in the superblock")
      :format(self.narena + nnew), 0)
  end

  -- pass 1: build the arenas. Nothing points at them yet, so a crash
  -- here is indistinguishable from never having called grow.
  local made = {}
  for i = 1, nnew do
    local a = {}
    initarena(self, a, off, asz)
    made[i] = a
    off = off + asz + 2 * blksz
  end
  self:devsync()

  -- pass 2: publish them, and move the backup superblock out to the new
  -- end of the device. sync() writes the superblock that makes all of it
  -- real, and until it returns none of this is on disk.
  local base = self.narena
  for i = 1, nnew do
    local a = made[i]
    self.arenas[base + i] = a
    self.arenabp[base + i] = { addr = a.h0.bp.addr, hash = a.h0.bp.hash,
      gen = -1 }
  end
  self.narena = base + nnew
  for i = base + 1, self.narena do
    local a = self.arenas[i]
    self:loadarena(a, self.arenabp[i])
    self:loadlog(a, a.loghd)
  end

  self.sb1 = blk.new(dat.Tsuper, eb, -1)
  self.sb1.data = self.sb0.data
  self:sync()

  return nnew, nnew * asz
end

--------------------------------------------------------------------------
-- shrink
--
-- The other direction, as far as it goes honestly. Only whole trailing
-- arenas holding nothing at all are dropped: nothing is evacuated and
-- nothing is rewritten, because relocating a block means rewriting the
-- pointer that names it, that pointer carries the block's hash, and the
-- parent holding it may belong to a snapshot that is not ours to
-- rewrite. So a volume that has spread data into its last arenas cannot
-- be shrunk, and says so by dropping nothing.
--
-- The ordering is grow's, reversed. The superblock naming fewer arenas
-- goes down first and the device is cut afterwards, so a crash in
-- between leaves a volume that is entirely correct and merely sitting on
-- a device larger than it admits to -- which is where grow starts.

-- Every block an arena still holds, or nil if it holds none of its own.
-- Its headers and its allocation log do not count: those go with it.
local function arenaresidue(fs, i, seen)
  local blksz = fs.geom.blksz
  local a = fs.arenas[i]

  local own = { [a.base] = true, [a.base + blksz] = true }
  local bp = a.loghd
  while bp.addr ~= -1 and not own[bp.addr] do
    own[bp.addr] = true
    local ok, b = pcall(fs.getblk, fs, bp, 0)
    if not ok then return "an unreadable log block" end
    bp = b.logp
  end

  local fi = 1
  for addr = a.base + 2 * blksz, a.base + a.size - blksz, blksz do
    while a.free[fi] ~= nil and a.free[fi].off + a.free[fi].len <= addr do
      fi = fi + 1
    end
    local r = a.free[fi]
    local free = r ~= nil and addr >= r.off and addr < r.off + r.len
    if not free and not own[addr] then
      -- allocated and not the arena's own: either something reaches it,
      -- or it is leaked and fsck should have it before we drop the
      -- ground out from under it
      return seen[addr] and ("a block in use at %d"):format(addr)
        or ("a leaked block at %d"):format(addr)
    end
  end
  return nil
end

-- Returns how many arenas were dropped, how many bytes that gave back,
-- and why it stopped.
function Fs:shrink(opts)
  opts = opts or {}
  if self.rdonly then error("shrink: filesystem is read only", 0) end
  local blksz = self.geom.blksz
  local keep = opts.keep or 1
  if keep < 1 then error("shrink: a volume needs an arena", 0) end

  -- Pending work can hold blocks anywhere, and deadlists settle in
  -- sync()'s last pass. What is on disk after this is what we judge.
  self:sync()

  local check = require "gefs.check"
  local fail = {}
  local seen = check.reachable(self, fail)
  if #fail > 0 then
    error("shrink: the volume is not sound: " .. fail[1], 0)
  end

  local ndrop, why = 0, nil
  while self.narena - ndrop > keep do
    local i = self.narena - ndrop
    if opts.max ~= nil and ndrop >= opts.max then why = "asked to stop" break end
    why = arenaresidue(self, i, seen)
    if why ~= nil then break end
    ndrop = ndrop + 1
  end
  if ndrop == 0 then return 0, 0, why or "no arenas to spare" end

  local bytes = 0
  for i = self.narena - ndrop + 1, self.narena do
    local a = self.arenas[i]
    bytes = bytes + a.size + 2 * blksz
    for addr = a.base, a.base + a.size + blksz, blksz do
      self:cachedel(addr)
    end
    self.arenas[i] = nil
    self.arenabp[i] = nil
  end
  self.narena = self.narena - ndrop

  local last = self.arenas[self.narena]
  local top = last.base + last.size + 2 * blksz
  local canresize = self.dev.resize ~= nil
  -- Without a device that can be cut the backup superblock stays where
  -- open() will look for it, at the end of a device that keeps its size.
  local sz = self.dev:size()
  local eb = canresize and top or (sz - sz % blksz - blksz)

  self.sb1 = blk.new(dat.Tsuper, eb, -1)
  self.sb1.data = self.sb0.data
  self:sync()
  if canresize then self.dev:resize(top + blksz) end

  return ndrop, bytes, why
end

--------------------------------------------------------------------------
-- open

function M.open(dev, opts)
  opts = opts or {}
  local sz = dev:size()

  -- The block size is in the superblock, so the first read cannot use
  -- it. Only the prefix is needed to find out, and the checksum covers
  -- exactly that prefix, so a short read is enough to verify it too.
  local probe = dev:read(0, math.min(dat.Blksz, sz))
  local fi, err = pack.unpacksb(probe)
  -- Falling back to the backup means guessing where it is, since the
  -- block size that locates it is in the superblock that just failed.
  -- The compiled-in size is the only guess available, and is right for
  -- every volume 9front makes.
  local blksz = fi and fi.blksz or dat.Blksz
  local eb = sz - sz % blksz - blksz

  if fi == nil then
    fi, err = pack.unpacksb(dev:read(eb, blksz))
    if fi == nil then
      error("cannot load either superblock: " .. tostring(err), 0)
    end
    eb = sz - sz % fi.blksz - fi.blksz
  end

  local geom = dat.geom(fi.blksz, fi.bufspc)
  local fs = newfs(dev, geom, opts)
  fs.narena = fi.narena
  fs.arenabp = fi.arenabp
  fs.flag = fi.flag
  fs.nextqid = fi.nextqid
  fs.nextgen = fi.nextgen
  fs.qgen = fi.qgen
  fs.snap.ht = fi.snap.ht
  fs.snap.bp = fi.snap.bp
  fs.snapdl.hd = fi.snapdl.hd
  fs.snapdl.tl = fi.snapdl.tl
  fs.sb0 = blk.new(dat.Tsuper, 0, -1)
  fs.sb1 = blk.new(dat.Tsuper, eb, -1)
  fs.sb0.data = dev:read(0, geom.blksz)
  fs.sb1.data = fs.sb0.data

  for i = 1, fs.narena do
    local a = {}
    fs.arenas[i] = a
    fs:loadarena(a, fs.arenabp[i])
  end
  for i = 1, fs.narena do
    fs:loadlog(fs.arenas[i], fs.arenas[i].loghd)
  end
  return fs
end

return M
