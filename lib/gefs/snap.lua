-- Snapshots, deadlists and the commit: gefs's snap.c, plus sync() from
-- fs.c.
--
-- A snapshot is free to take, because every write already shadows the
-- blocks it touches: labelling the current root is the whole operation.
-- What is not free is deciding when a shadowed block may be reused, and
-- that is what a deadlist is. When a tree frees a block that was born
-- before the tree's own generation, the block is not returned to the
-- arena -- some older snapshot may still reach it -- but appended to the
-- list of blocks that die with this snapshot. Dropping the snapshot
-- walks the list and frees them; keeping it costs eight bytes.
--
-- The four passes at the bottom are the crash story. Arena headers
-- first, then the superblocks, then the arena footers: a crash between
-- any two of them leaves either the old superblock with a consistent set
-- of headers, or the new one with a consistent set, and never a
-- superblock pointing at a tree whose blocks were not written.

local dat = require "gefs.dat"
local pack = require "gefs.pack"
local Fs = require "gefs.obj"

local M = {}

--------------------------------------------------------------------------
-- deadlists

local function dlkey(gen, bgen)
  return gen .. ":" .. bgen
end

function Fs:dlflush(dl)
  if dl.ins == nil then return end
  dl.hd = dl.ins.bp
  if dl.tl.addr == dl.hd.addr then dl.tl = dl.hd end
  dl.ins.pinned = false
  self:enqueue(dl.ins)
  dl.ins = nil
  -- the snap tree's own deadlist has gen -1 and lives in the superblock;
  -- every other one is a key in the snap tree
  if dl.gen ~= -1 then
    local k, v = pack.dlist2kv(dl)
    self:btupsert(self.snap, { { op = dat.Oinsert, k = k, v = v } })
  end
end

function Fs:dlcachedel(dl)
  local key = dlkey(dl.gen, dl.bgen)
  if self.dlcache[key] ~= nil then
    self.dlcache[key] = nil
    self.dlcount = self.dlcount - 1
  end
  for i, d in ipairs(self.dlorder) do
    if d == dl then table.remove(self.dlorder, i); break end
  end
end

function Fs:getdl(gen, bgen)
  local key = dlkey(gen, bgen)
  local dl = self.dlcache[key]
  if dl ~= nil then return dl end

  dl = { gen = gen, bgen = bgen, hd = dat.zb(), tl = dat.zb(), ins = nil }
  local k = string.pack(">I1i8i8", dat.Kdlist, gen, bgen)
  local kv = self:btlookup(self.snap, k)
  if kv ~= nil then
    local got = pack.kv2dlist(kv.k, kv.v)
    dl.hd, dl.tl = got.hd, got.tl
  else
    local nk, nv = pack.dlist2kv(dl)
    self:btupsert(self.snap, { { op = dat.Oinsert, k = nk, v = nv } })
  end

  self.dlcache[key] = dl
  self.dlcount = self.dlcount + 1
  self.dlorder[#self.dlorder + 1] = dl
  return dl
end

-- Release a deadlist back to the cache, flushing whichever ones have
-- aged out. The snap tree's own list is never cached: it is a field, not
-- a key, and comparing it by identity would be comparing against a
-- structure that moves.
function Fs:putdl(dl)
  if dl.gen == -1 then return end
  while self.dlcount > self.dlcmax do
    local dt = table.remove(self.dlorder, 1)
    if dt == nil then break end
    self.dlcache[dlkey(dt.gen, dt.bgen)] = nil
    self.dlcount = self.dlcount - 1
    if dt ~= dl then self:dlflush(dt) end
  end
end

function Fs:dlsync()
  self:dlflush(self.snapdl)
  local all = {}
  for _, dl in ipairs(self.dlorder) do all[#all + 1] = dl end
  for _, dl in ipairs(all) do self:dlflush(dl) end
end

-- Mark a block as killed by tree t: it stops being reachable now, and
-- becomes free when t is reclaimed.
function Fs:killblk(t, bp)
  local dl
  if t == self.snap then
    dl = self.snapdl
  elseif bp.gen > t.base then
    dl = self:getdl(t.memgen, bp.gen)
  else
    -- a forked snapshot: blocks older than the fork belong to the other
    -- chain, and the last reference over there cleans them up
    return
  end

  if dl.ins == nil or self.geom.logspc - dl.ins.logsz < dat.Logslop then
    local b = self:newblk(self.snap, dat.Tdlist)
    if dl.ins ~= nil then
      self:enqueue(dl.ins)
    end
    if dl.tl.addr == -1 then dl.tl = b.bp end
    b.logp = dl.hd
    dl.hd = b.bp
    dl.ins = b
    -- The open block goes in the cache unwritten and pinned there. A
    -- deadlist that is reclaimed before the next commit is walked from
    -- its head and freed, and this block has to be findable by address
    -- for that walk even though it never reached the disk.
    b.pinned = true
    self:cacheins(b)
  end
  dl.ins.logents[#dl.ins.logents + 1] = string.pack(">i8", bp.addr)
  dl.ins.logsz = dl.ins.logsz + 8
  dl.ins.dirty = true
  self:putdl(dl)
end

-- Walk a deadlist chain, freeing the blocks it names when asked and the
-- chain's own blocks always.
function Fs:freedl(dl, dofree)
  local bp = dl.hd
  local done = false
  while bp.addr ~= -1 and not done do
    local b = self:getblk(bp, 0)
    if dofree then
      for _, e in ipairs(b.logents) do
        local addr = string.unpack(">i8", e)
        self:cachedel(addr)
        self:blkdealloc(self:getarena(addr), addr)
      end
    end
    done = (bp.addr == dl.tl.addr)
    bp = b.logp
    self:cachedel(b.bp.addr)
    self:blkdealloc(self:getarena(b.bp.addr), b.bp.addr)
  end
  dl.hd = dat.zb()
  dl.tl = dat.zb()
  dl.ins = nil
end

-- Append m's chain onto d's. Used when a snapshot is folded into its
-- successor: the successor inherits everything the dead one was keeping
-- alive.
function Fs:splicedl(d, m)
  assert(d ~= m, "splicing a deadlist onto itself")
  if m.hd.addr == -1 then return end
  if d.hd.addr == -1 then
    assert(d.ins == nil, "splicing onto an open deadlist")
    d.hd, d.tl, d.ins = m.hd, m.tl, m.ins
    m.ins = nil
  else
    if m.ins ~= nil then
      self:enqueue(m.ins)
      m.ins = nil
    end
    local b = self:getblk(d.tl, 0)
    b.logp = m.hd
    d.tl = m.tl
    assert(d.hd.addr ~= m.hd.addr, "deadlist spliced onto its own head")
    -- dlflush writes the open tail, so this must not
    if b ~= d.ins then self:enqueue(b) end
  end
  m.hd = dat.zb()
  m.tl = dat.zb()
end

function Fs:mergedl(merge, gen, bgen)
  local d = self:getdl(merge, bgen)
  local m = self:getdl(gen, bgen)
  self:splicedl(d, m)
  local mk, mv = pack.dlist2kv(m)
  local dk, dv = pack.dlist2kv(d)
  self:btupsert(self.snap, {
    { op = dat.Odelete, k = mk, v = "" },
    { op = dat.Oinsert, k = dk, v = dv },
  })
  self:dlcachedel(m)
  self:putdl(d)
end

function Fs:dropdlist(gen, bgen, succ)
  local d = self:getdl(gen, bgen)
  local k = pack.dlist2kv(d)
  self:btupsert(self.snap, { { op = dat.Odelete, k = k, v = "" } })
  assert(d.ins == nil, "dropping an open deadlist")
  self:dlcachedel(d)
  -- With no successor, sweeptree frees the contents and only the
  -- deadlist's own blocks are left over; with one, the contents are
  -- still live for the successor and go on the snap tree's list.
  if succ == -1 then
    self:splicedl(self.dropdl, d)
  else
    self:splicedl(self.snapdl, d)
  end
end

function Fs:reclaimblocks(gen, succ, prev)
  local pfx = string.pack(">I1i8", dat.Kdlist, gen)
  local todo = {}
  local s = self:btscan(self.snap, pfx)
  for kv in s:iter() do
    todo[#todo + 1] = pack.kv2dlist(kv.k, kv.v)
  end
  s:close()
  for _, dl in ipairs(todo) do
    if succ ~= -1 and dl.bgen <= prev then
      self:mergedl(succ, dl.gen, dl.bgen)
    else
      self:dropdlist(dl.gen, dl.bgen, succ)
    end
  end

  if succ ~= -1 then
    todo = {}
    s = self:btscan(self.snap, string.pack(">I1i8", dat.Kdlist, succ))
    for kv in s:iter() do
      local dl = pack.kv2dlist(kv.k, kv.v)
      if dl.bgen > prev then todo[#todo + 1] = dl end
    end
    s:close()
    for _, dl in ipairs(todo) do
      self:dropdlist(dl.gen, dl.bgen, succ)
    end
  end
end

--------------------------------------------------------------------------
-- opening snapshots

function Fs:opentree(gen)
  for _, mnt in ipairs(self.mounts) do
    if mnt.root.gen == gen then
      mnt.root.memref = mnt.root.memref + 1
      return mnt.root
    end
  end
  local kv = self:btlookup(self.snap, pack.packsnap(gen))
  if kv == nil then error(("no snapshot %d"):format(gen), 0) end
  local t = pack.unpacktree(kv.v)
  t.memref = 1
  t.memgen = self.nextgen; self.nextgen = self.nextgen + 1
  t.dirty = false
  return t
end

function Fs:opensnap(label)
  local kv = self:btlookup(self.snap, pack.packlbl(label))
  if kv == nil then return nil end
  local gen, flg = pack.kv2lbl(kv.v)
  return self:opentree(gen), flg
end

function Fs:closesnap(t)
  if t == nil then return end
  t.memref = t.memref - 1
end

--------------------------------------------------------------------------
-- labelling
--
-- A mutable label gets a fresh generation, so the snapshot it was
-- pointing at becomes immutable and the label keeps moving. An immutable
-- one just takes a reference to what is already there.

local RESERVED = { dump = true, empty = true, adm = true }

function Fs:tagsnap(t, name, flg)
  if RESERVED[name] then error("reserved snapshot name: " .. name, 0) end

  local m = {}
  if flg & dat.Lmut ~= 0 then
    local kv = self:btlookup(self.snap, pack.packsnap(t.gen))
    if kv == nil then error("snapshot vanished", 0) end
    local c = pack.unpacktree(kv.v)

    local n = {
      nlbl = 1, nref = 0, ht = c.ht, bp = c.bp,
      succ = -1, pred = -1, base = t.gen, flag = 0,
      gen = self.nextgen, dirty = false,
    }
    self.nextgen = self.nextgen + 1
    n.memgen = self.nextgen
    self.nextgen = self.nextgen + 1

    t.nref = t.nref + 1
    local k, v = pack.retag2kv(t.gen, -1, 0, 1)
    m[#m + 1] = { op = dat.Oincref, k = k, v = v }
    k, v = pack.lbl2kv(name, n.gen, flg)
    m[#m + 1] = { op = dat.Oinsert, k = k, v = v }
    k, v = pack.tree2kv(n)
    m[#m + 1] = { op = dat.Oinsert, k = k, v = v }
  else
    t.nlbl = t.nlbl + 1
    local k, v = pack.retag2kv(t.gen, t.succ, 1, 0)
    m[#m + 1] = { op = dat.Orelink, k = k, v = v }
    k, v = pack.lbl2kv(name, t.gen, flg)
    m[#m + 1] = { op = dat.Oinsert, k = k, v = v }
  end
  self:btupsert(self.snap, m)
end

-- Move a mutable label forward. The generation stays put as long as the
-- snapshot is at the tip of its list; once something derived from it can
-- see it, it has to become immutable and the label moves to a new one.
function Fs:updatesnap(o, lbl, flg)
  assert(flg & dat.Lmut ~= 0, "updating an immutable label")
  if not o.dirty then return o end

  local t = {
    memref = 1, dirty = false,
    nlbl = 1, nref = 0,
    ht = o.ht, bp = o.bp,
    succ = -1, base = o.base, flag = o.flag or 0,
    gen = o.memgen,
  }
  t.memgen = self.nextgen; self.nextgen = self.nextgen + 1

  local m = {}
  o.nlbl = o.nlbl - 1
  if o.nlbl == 0 and o.nref == 0 then
    t.pred = o.pred
    if t.pred ~= -1 then
      local k, v = pack.retag2kv(t.pred, t.gen, 0, 0)
      m[#m + 1] = { op = dat.Orelink, k = k, v = v }
    end
  else
    t.pred = o.gen
    local k, v = pack.retag2kv(t.pred, t.gen, -1, 0)
    m[#m + 1] = { op = dat.Orelink, k = k, v = v }
  end

  local k, v = pack.tree2kv(t)
  m[#m + 1] = { op = dat.Oinsert, k = k, v = v }
  k, v = pack.lbl2kv(lbl, t.gen, flg)
  m[#m + 1] = { op = dat.Oinsert, k = k, v = v }
  self:btupsert(self.snap, m)

  o.dirty = false
  if o.nlbl == 0 and o.nref == 0 then
    self:delsnap(o, t.gen, nil)
  end
  return t
end

-- Take a label off a snapshot. A snapshot with no labels and no forks is
-- reclaimed; with exactly one successor it folds into it. Reports
-- whether the tree still has to be swept.
function Fs:delsnap(t, succ, name)
  local m = {}
  local del = false

  if name ~= nil then
    if RESERVED[name] then error("reserved snapshot name: " .. name, 0) end
    m[#m + 1] = { op = dat.Odelete, k = pack.packlbl(name), v = "" }
    t.nlbl = t.nlbl - 1
  end

  if t.nlbl == 0 and t.nref == 0 then
    del = true
    if t.pred ~= -1 then
      local k, v = pack.retag2kv(t.pred, succ, 0, 0)
      m[#m + 1] = { op = dat.Orelink, k = k, v = v }
    end
    if t.succ ~= -1 then
      local k, v = pack.retag2kv(t.succ, t.pred, 0, 0)
      m[#m + 1] = { op = dat.Oreprev, k = k, v = v }
    end
    if t.pred == -1 and succ == -1 then
      local k, v = pack.retag2kv(t.base, -1, 0, -1)
      m[#m + 1] = { op = dat.Oincref, k = k, v = v }
    end
    m[#m + 1] = { op = dat.Odelete, k = pack.packsnap(t.gen), v = "" }
  else
    assert(name ~= nil, "dropping a snapshot that is still referenced")
    local k, v = pack.retag2kv(t.gen, t.succ, -1, 0)
    m[#m + 1] = { op = dat.Orelink, k = k, v = v }
  end

  self:dlsync()
  self:btupsert(self.snap, m)

  if del then
    self:reclaimblocks(t.gen, succ, t.pred)
    for _, mnt in ipairs(self.mounts) do
      local r = mnt.root
      if r.gen == t.succ then r.pred = t.pred end
      if r.gen == t.pred then r.succ = succ end
    end
  end
  return del and succ == -1
end

--------------------------------------------------------------------------
-- reclaiming a tree nobody can reach

function Fs:freetree(rb, pred)
  local b = self:getblk(rb, 0)
  if b.type == dat.Tpivot then
    for i = 1, #b.vals do
      self:freetree(pack.unpackbp(b.vals[i].v), pred)
    end
  end
  if rb.gen > pred then self:freeblk(nil, b) end
end

-- The last reference to a tree is going away, so every data block it
-- allocated after its base goes too, then the tree itself.
function Fs:sweeptree(t)
  local gen = (t.pred ~= -1) and t.pred or t.base
  local dead = {}
  local s = self:btscan(t, string.pack(">I1", dat.Kdat))
  for kv in s:iter() do
    local bp = pack.unpackbp(kv.v)
    if bp.gen > gen then dead[#dead + 1] = bp end
  end
  s:close()
  for _, bp in ipairs(dead) do self:freebp(nil, bp) end
  self:freetree(t.bp, gen)

  if gen ~= -1 then
    local ok, n = pcall(self.opentree, self, gen)
    if ok and n.nlbl == 0 and n.nref == 0 then return n end
  end
  return nil
end

--------------------------------------------------------------------------
-- taking and dropping named snapshots

function Fs:snapshot(old, new, flg)
  flg = flg or 0
  local t, mnt
  for _, mm in ipairs(self.mounts) do
    if mm.name == old then
      mnt = mm
      if mm.flag & dat.Lmut ~= 0 then
        mm.root = self:updatesnap(mm.root, mm.name, mm.flag)
      end
      t = mm.root
      t.memref = (t.memref or 1) + 1
      break
    end
  end
  if t == nil then
    t = self:opensnap(old)
    if t == nil then error("no such snapshot: " .. old, 0) end
  end
  if self:opensnap(new) ~= nil then
    error("snapshot exists: " .. new, 0)
  end
  self:tagsnap(t, new, flg)
  self:closesnap(t)
  self.snap.dirty = true
end

function Fs:delsnapshot(name)
  for _, mnt in ipairs(self.mounts) do
    if mnt.name == name then
      error("snapshot is in use: " .. name, 0)
    end
  end
  local t = self:opensnap(name)
  if t == nil then error("no such snapshot: " .. name, 0) end
  local sweep = self:delsnap(t, t.succ, name)
  self.snap.dirty = true
  while sweep do
    self:sync()
    local n = self:sweeptree(t)
    if n == nil then break end
    t = n
    if n.nref == 0 and n.nlbl == 0 then
      sweep = self:delsnap(n, n.succ, nil)
    else
      break
    end
  end
end

--------------------------------------------------------------------------
-- the commit

function Fs:sync()
  if self.rdonly then error("filesystem is read only", 0) end
  local blksz = self.geom.blksz

  self.qgen = self.qgen + 1

  -- pass 0: move the mutable labels forward, settle the deadlists, and
  -- pack everything that the next three passes will write
  for _, mnt in ipairs(self.mounts) do
    if mnt.flag & dat.Lmut ~= 0 then
      mnt.root = self:updatesnap(mnt.root, mnt.name, mnt.flag)
    end
  end

  -- the snap tree stops changing here, so the deadlists can settle
  self:dlsync()
  local sdl = { gen = -1, hd = self.snapdl.hd, tl = self.snapdl.tl }
  local ddl = { gen = -1, hd = self.dropdl.hd, tl = self.dropdl.tl }
  self.snapdl.hd, self.snapdl.tl, self.snapdl.ins = dat.zb(), dat.zb(), nil
  self.dropdl.hd, self.dropdl.tl, self.dropdl.ins = dat.zb(), dat.zb(), nil

  for i = 1, self.narena do
    local a = self.arenas[i]
    -- the log reuses preallocated blocks, so its tail must reach disk
    -- before anything can hand those blocks out again
    self:logbarrier(a, self.qgen)
    self:flushlog(a)
    a.h0.arena = { loghd = a.loghd, size = a.size, used = a.used }
    a.h1.arena = a.h0.arena
    -- packed now rather than at write time, because the superblock
    -- carries the hash of the header and has to see the final bytes
    self:finalize(a.h0)
    self:finalize(a.h1)
    self.arenabp[i] = { addr = a.h0.bp.addr, hash = a.h0.bp.hash, gen = -1 }
  end

  assert(self.snapdl.hd.addr == -1, "the snap deadlist grew during a sync")

  -- self.snapdl, not sdl: the chain sdl names is freed in pass 4, so
  -- recording it would leave the committed superblock pointing at blocks
  -- that this very commit gives back. What goes on disk is the reset
  -- list, which the assertion above says is empty.
  local sb = pack.packsb({
    bufspc = self.geom.bufspc, narena = self.narena,
    snap = self.snap, snapdl = self.snapdl,
    flag = self.flag, nextqid = self.nextqid,
    nextgen = self.nextgen, qgen = self.qgen,
    arenabp = self.arenabp,
  }, blksz)
  sb = sb .. string.rep("\0", blksz - #sb)
  self.sb0.data = sb
  self.sb1.data = sb
  self:finalize(self.sb0)
  self:finalize(self.sb1)

  -- pass 1: arena headers. A crash here leaves the footers consistent
  -- with the superblock still on disk.
  for i = 1, self.narena do
    self:enqueue(self.arenas[i].h0)
  end
  self:devsync()

  -- pass 2: the superblocks. Past this the new tree is the tree.
  self:enqueue(self.sb0)
  self:enqueue(self.sb1)
  self:devsync()

  -- pass 3: arena footers, so the next load has two good copies again
  for i = 1, self.narena do
    self:enqueue(self.arenas[i].h1)
  end
  self:devsync()

  -- pass 4: only now is it safe to reuse what the old tree was holding
  self:freedl(ddl, false)
  self:freedl(sdl, true)
  self.snap.dirty = false
end

return M
