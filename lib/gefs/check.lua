-- The consistency checker: gefs's check.c.
--
-- This exists to be run after every operation in a torture test, which
-- is a thing the C cannot afford and Lua can. What it asserts is what
-- the tree's own algorithms assume and never verify: that keys are in
-- order and unique within a node, that every node's range is inside its
-- parent's, that the tree is balanced, that a pivot's recorded fill
-- matches what its child actually holds, and that nothing reachable
-- lives in an arena's free list.
--
-- The fill check is the one worth naming. Nothing reads a fill except
-- trybalance, so a wrong fill produces a tree that is correct and
-- gradually degenerates, which no functional test will ever notice.

local dat = require "gefs.dat"
local blk = require "gefs.blk"
local pack = require "gefs.pack"
local store = require "gefs.store"
local Fs = require "gefs.obj"

local M = {}

local keycmp = blk.keycmp

-- Recomputed from the entries rather than read off the block, so that a
-- fill this checker disagrees with is a fill the tree got wrong. Asking
-- Blk:fill() would be asking the same code twice and agreeing with
-- itself, which is exactly the mistake this check exists to catch.
-- An entry costs its own two-byte offset slot plus a length-prefixed key
-- and value, and a message costs one more byte for its op.
local function fillof(b)
  local n = 0
  for _, kv in ipairs(b.vals) do n = n + 2 + (2 + #kv.k + 2 + #kv.v) end
  if b.type == dat.Tpivot then
    for _, m in ipairs(b.msgs) do n = n + 2 + (1 + 2 + #m.k + 2 + #m.v) end
  end
  return n
end

local function isfree(fs, addr)
  local ok, a = pcall(fs.getarena, fs, addr)
  if not ok then return false end
  local i = store.rsearch(a.free, addr)
  local r = a.free[i]
  if r == nil then return false end
  return addr < r.off + r.len
end

local function checktree(fs, b, h, pred, lo, hi, fail, seen)
  if h < 0 then
    fail[#fail + 1] = "node too deep (a loop?)"
    return
  end

  if seen[b.bp.addr] then
    fail[#fail + 1] = ("block %d appears twice in one tree"):format(b.bp.addr)
    return
  end
  seen[b.bp.addr] = true

  if b.type == dat.Tleaf and h ~= 0 then
    fail[#fail + 1] = "unbalanced leaf"
  end
  if b.type == dat.Tpivot and h == 0 then
    fail[#fail + 1] = "pivot where a leaf belongs"
  end
  if #b.vals == 0 then
    fail[#fail + 1] = ("empty node at %d"):format(b.bp.addr)
    return
  end

  local x = b.vals[1]
  if lo ~= nil and keycmp(lo, x.k) > 0 then
    fail[#fail + 1] = "keys below the node's range"
  end

  local function descend(kv, klo, khi)
    local bp, fill = blk.getptr(kv)
    if bp.gen <= pred then return end
    if isfree(fs, bp.addr) then
      fail[#fail + 1] = ("freed block in use: %d"):format(bp.addr)
      return
    end
    local ok, c = pcall(fs.getblk, fs, bp, 0)
    if not ok then
      fail[#fail + 1] = ("corrupt block at %d: %s"):format(bp.addr, tostring(c))
      return
    end
    if fillof(c) ~= fill then
      fail[#fail + 1] = ("mismatched fill at %d: %d recorded, %d actual")
        :format(bp.addr, fill, fillof(c))
    end
    if c:fill() ~= fillof(c) then
      fail[#fail + 1] = ("block %d disagrees with itself about its fill")
        :format(bp.addr)
    end
    checktree(fs, c, h - 1, pred, klo, khi, fail, seen)
  end

  for i = 2, #b.vals do
    local y = b.vals[i]
    if hi ~= nil and keycmp(y.k, hi) >= 0 then
      fail[#fail + 1] = "keys above the node's range"
    end
    if b.type == dat.Tpivot then descend(x, x.k, y.k) end
    local r = keycmp(x.k, y.k)
    if r == 0 then
      fail[#fail + 1] = "duplicate keys in one node"
    elseif r == 1 then
      fail[#fail + 1] = "misordered keys in one node"
    end
    x = y
  end

  if b.type == dat.Tpivot then
    descend(b.vals[#b.vals], b.vals[#b.vals].k, nil)

    if #b.msgs > 0 then
      local mx = b.msgs[1]
      if hi ~= nil and keycmp(mx.k, hi) >= 0 then
        fail[#fail + 1] = "buffered message above the node's range"
      end
      for i = 2, #b.msgs do
        local my = b.msgs[i]
        if my.op == dat.Owstat then
          local allowed = dat.Owsize | dat.Owmode | dat.Owmtime | dat.Owatime
            | dat.Owuid | dat.Owgid | dat.Owmuid
          if my.v:byte(1) & ~allowed ~= 0 then
            fail[#fail + 1] = ("invalid wstat op %x"):format(my.v:byte(1))
          end
        elseif my.op <= dat.Onop or my.op >= dat.Nmsgtype then
          fail[#fail + 1] = ("invalid message op %s"):format(tostring(my.op))
        end
        if keycmp(mx.k, my.k) == 1 then
          fail[#fail + 1] = "misordered messages in one buffer"
          break
        end
        mx = my
      end
    end
  end
end

local function checklog(fs, hd, tl, fail)
  local pb = dat.zb()
  local bp = hd
  local guard = 0
  while bp.addr ~= -1 do
    guard = guard + 1
    if guard > 1 << 20 then
      fail[#fail + 1] = "log chain does not terminate"
      return
    end
    local ok, b = pcall(fs.getblk, fs, bp, 0)
    if not ok then
      fail[#fail + 1] = ("cannot load log block %d: %s")
        :format(bp.addr, tostring(b))
      return
    end
    pb = bp
    bp = b.logp
    if pb.addr == tl.addr then break end
  end
  if tl.addr ~= -1 and pb.addr ~= tl.addr then
    fail[#fail + 1] = ("truncated log chain from %d"):format(hd.addr)
  end
end

-- Check one tree. Blocks born at or before pred belong to an older
-- snapshot and are somebody else's to account for, which is why the
-- descent stops at them.
function Fs:checktree(t, fail)
  fail = fail or {}
  local ok, b = pcall(self.getblk, self, t.bp, 0)
  if not ok then
    fail[#fail + 1] = ("cannot load root %d: %s"):format(t.bp.addr, tostring(b))
    return fail
  end
  local pred = (t.pred ~= nil and t.pred ~= -1) and t.pred or -1
  checktree(self, b, t.ht - 1, pred, nil, nil, fail, {})
  return fail
end

-- Everything: the snapshot tree, every tree that is mounted, every tree
-- the snapshot tree names, and each arena's log. Returns the list of
-- complaints, empty when the volume is sound.
--
-- The mounted trees matter as much as the recorded ones. A mount's root
-- moves with every write and is only written into the snapshot tree at
-- the next commit, so checking the recorded trees alone would be
-- checking the state as of the last sync and calling it current.
function Fs:check(opts)
  opts = opts or {}
  local fail = {}

  self:checktree(self.snap, fail)

  for _, mnt in ipairs(self.mounts) do
    local sub = {}
    self:checktree(mnt.root, sub)
    for _, e in ipairs(sub) do
      fail[#fail + 1] = ("mount %s: %s"):format(mnt.name, e)
    end
  end

  local gens = {}
  local s = self:btscan(self.snap, string.pack(">I1", dat.Ksnap))
  for kv in s:iter() do
    gens[#gens + 1] = pack.unpacktree(kv.v)
  end
  s:close()

  for _, t in ipairs(gens) do
    if t.ht > 0 and t.bp.addr ~= -1 then
      local sub = {}
      checktree(self, self:getblk(t.bp, 0), t.ht - 1,
        t.pred ~= -1 and t.pred or -1, nil, nil, sub, {})
      for _, e in ipairs(sub) do
        fail[#fail + 1] = ("snap %d: %s"):format(t.gen, e)
      end
    end
  end

  -- every label names a snapshot that exists
  s = self:btscan(self.snap, string.pack(">I1", dat.Klabel))
  for kv in s:iter() do
    local gen = pack.kv2lbl(kv.v)
    local found = false
    for _, t in ipairs(gens) do
      if t.gen == gen then found = true; break end
    end
    if not found then
      fail[#fail + 1] = ("label %q names missing snapshot %d")
        :format(kv.k:sub(2), gen)
    end
  end
  s:close()

  if not opts.nolog then
    for i = 1, self.narena do
      local a = self.arenas[i]
      checklog(self, a.loghd, a.logtl and a.logtl.bp or dat.zb(), fail)

      -- free ranges must be disjoint, ordered and inside the arena
      local prev = nil
      for _, r in ipairs(a.free) do
        if r.len <= 0 then
          fail[#fail + 1] = ("arena %d: empty free range"):format(i)
        end
        if prev ~= nil and prev.off + prev.len >= r.off then
          fail[#fail + 1] = ("arena %d: overlapping free ranges"):format(i)
        end
        if r.off < a.base or r.off + r.len > a.base + a.size + 2 * self.geom.blksz then
          fail[#fail + 1] = ("arena %d: free range outside the arena"):format(i)
        end
        prev = r
      end
    end
  end

  return fail
end

M.checklog = checklog

--------------------------------------------------------------------------
-- the deep pass
--
-- Everything above checks that each structure is internally consistent.
-- This checks the things that only show up when you look at the whole
-- volume at once: blocks that nothing points at, dirents whose parent is
-- gone, file data belonging to files that are not there. None of it is
-- reachable from any one node, so none of it can be checked on the way
-- past.

-- Walk every block a tree can reach, including the data blocks its Kdat
-- entries point at.
--
-- No generation filtering here, unlike checktree: a sweep looking for
-- blocks nothing points at has to follow every pointer, including the
-- ones into an ancestor snapshot's blocks. Shared subtrees cost nothing
-- to revisit because seen stops them. The root pointer in particular
-- must never be filtered -- the superblock records no generation for the
-- snap tree, so its gen is -1 and any such test would skip the whole
-- volume.
local function reach(fs, bp, seen, fail, where)
  if bp.addr == -1 or seen[bp.addr] then return end
  seen[bp.addr] = true

  local ok, b = pcall(fs.getblk, fs, bp, 0)
  if not ok then
    fail[#fail + 1] = ("%s: cannot read %d: %s")
      :format(where, bp.addr, tostring(b))
    return
  end
  if b.type == dat.Tpivot then
    for _, kv in ipairs(b.vals) do
      reach(fs, pack.unpackbp(kv.v), seen, fail, where)
    end
  elseif b.type == dat.Tleaf then
    for _, kv in ipairs(b.vals) do
      if #kv.k > 0 and kv.k:byte(1) == dat.Kdat then
        local d = pack.unpackbp(kv.v)
        if d.addr ~= -1 then seen[d.addr] = true end
      end
    end
  end
end

-- Data blocks are pointed at from leaves but never descended into, so a
-- pivot's buffered Kdat messages hold pointers too. They are live until
-- the message is applied.
local function reachmsgs(fs, bp, seen)
  if bp.addr == -1 then return end
  local ok, b = pcall(fs.getblk, fs, bp, 0)
  if not ok or b.type ~= dat.Tpivot then return end
  for _, m in ipairs(b.msgs) do
    if m.op == dat.Oinsert and #m.k > 0 and m.k:byte(1) == dat.Kdat
      and #m.v >= dat.Ptrsz then
      local d = pack.unpackbp(m.v)
      if d.addr ~= -1 then seen[d.addr] = true end
    end
  end
  for _, kv in ipairs(b.vals) do
    reachmsgs(fs, pack.unpackbp(kv.v), seen)
  end
end

local function reachable(fs, fail)
  local seen = {}
  local blksz = fs.geom.blksz

  seen[fs.sb0.bp.addr] = true
  seen[fs.sb1.bp.addr] = true

  for i = 1, fs.narena do
    local a = fs.arenas[i]
    seen[a.base] = true
    seen[a.base + blksz] = true
    -- the allocation log, which is not part of any tree
    local bp = a.loghd
    local guard = 0
    while bp.addr ~= -1 and not seen[bp.addr] and guard < (1 << 20) do
      seen[bp.addr] = true
      guard = guard + 1
      local ok, b = pcall(fs.getblk, fs, bp, 0)
      if not ok then break end
      bp = b.logp
    end
  end

  local function tree(t, where)
    reach(fs, t.bp, seen, fail, where)
    reachmsgs(fs, t.bp, seen)
  end

  tree(fs.snap, "snap tree")
  for _, mnt in ipairs(fs.mounts) do tree(mnt.root, "mount " .. mnt.name) end

  local s = fs:btscan(fs.snap, string.pack(">I1", dat.Ksnap))
  local gens = {}
  for kv in s:iter() do gens[#gens + 1] = pack.unpacktree(kv.v) end
  s:close()
  for _, t in ipairs(gens) do
    tree(t, ("snap %d"):format(t.gen))
  end

  -- Deadlist chains. Their blocks are allocated and belong to no tree,
  -- so a sweep that missed them would call every one a leak.
  -- A deadlist owns two kinds of block: the ones its chain is made of,
  -- and the ones it names. The named ones are dead -- no tree reaches
  -- them any more -- but they stay allocated until the deadlist is
  -- reclaimed, so they are the deadlist's to account for and not leaks.
  --
  -- The loop guard is a set of its own rather than `seen`, because two
  -- deadlists can share a chain after a splice and stopping at the first
  -- block already marked would truncate the walk.
  local function walkdl(dl, what)
    local bp = dl.hd
    local along = {}
    while bp.addr ~= -1 and not along[bp.addr] do
      along[bp.addr] = true
      seen[bp.addr] = true
      local ok, b = pcall(fs.getblk, fs, bp, 0)
      if not ok then
        fail[#fail + 1] = ("%s: cannot read %d: %s")
          :format(what, bp.addr, tostring(b))
        return
      end
      for _, e in ipairs(b.logents) do
        seen[string.unpack(">i8", e)] = true
      end
      if bp.addr == dl.tl.addr then return end
      bp = b.logp
    end
  end

  -- The ones in memory first. A deadlist records its head in the snap
  -- tree only when it is flushed, so between a block being killed and
  -- the next flush the chain on disk is shorter than the real one. Those
  -- blocks are allocated and reachable only from here.
  walkdl(fs.snapdl, "snap deadlist")
  walkdl(fs.dropdl, "dropped deadlist")
  for _, dl in ipairs(fs.dlorder) do
    walkdl(dl, ("deadlist %d/%d"):format(dl.gen, dl.bgen))
  end

  s = fs:btscan(fs.snap, string.pack(">I1", dat.Kdlist))
  local recorded = {}
  for kv in s:iter() do
    recorded[#recorded + 1] = pack.kv2dlist(kv.k, kv.v)
  end
  s:close()
  for _, dl in ipairs(recorded) do
    walkdl(dl, ("deadlist %d/%d"):format(dl.gen, dl.bgen))
  end

  return seen
end

-- Blocks that are allocated and that nothing points at. A leak is not
-- corruption -- the volume reads correctly, it just never gets the space
-- back -- which is exactly why nothing else notices one.
--
-- One source of them is built into the commit and worth naming, because
-- it is not a bug and will show up on any volume that was closed cleanly.
-- sync() reclaims the old tree's blocks in its last pass, after the
-- superblock has already been written. Those frees go into the
-- allocation log after the barrier that superblock names, so a reload
-- replays up to the barrier and stops without them. The next commit
-- makes them durable; stopping before it loses them. Reclaiming the
-- space is what fix is for.
local function leaks(fs, seen, opts)
  local blksz = fs.geom.blksz
  local found = {}
  for i = 1, fs.narena do
    local a = fs.arenas[i]
    -- the two headers are outside the allocatable span, and the two
    -- blocks of slack at the far end were never handed out
    local lo = a.base + 2 * blksz
    local hi = a.base + a.size
    local fi = 1
    for addr = lo, hi - blksz, blksz do
      while a.free[fi] ~= nil and a.free[fi].off + a.free[fi].len <= addr do
        fi = fi + 1
      end
      local r = a.free[fi]
      local free = r ~= nil and addr >= r.off and addr < r.off + r.len
      if not free and not seen[addr] then
        found[#found + 1] = { addr = addr, arena = i }
      end
    end
  end
  return found
end

-- The namespace: every dirent's parent exists and is a directory, every
-- directory has the back pointer that makes ".." work, no qid is used
-- twice, and no file data belongs to a file that is not there.
local function namespace(fs, t, fail, where)
  local ents = {}
  local qids = {}
  local ups = {}

  local s = fs:btscan(t, string.pack(">I1", dat.Kent))
  for kv in s:iter() do
    local ok, d = pcall(pack.kv2dir, kv.k, kv.v)
    if not ok then
      fail[#fail + 1] = ("%s: unreadable dirent"):format(where)
    else
      local up = string.unpack(">i8", kv.k, 2)
      d.up = up
      if qids[d.qid.path] ~= nil then
        fail[#fail + 1] = ("%s: qid %d is used by both %q and %q")
          :format(where, d.qid.path, qids[d.qid.path], d.name)
      end
      qids[d.qid.path] = d.name
      ents[#ents + 1] = d
    end
  end
  s:close()

  s = fs:btscan(t, string.pack(">I1", dat.Kup))
  for kv in s:iter() do
    local qid = string.unpack(">i8", kv.k, 2)
    local ok, up, name = pcall(pack.unpackdkey, kv.v)
    if not ok then
      fail[#fail + 1] = ("%s: unreadable parent link for qid %d")
        :format(where, qid)
    else
      ups[qid] = { up = up, name = name }
    end
  end
  s:close()

  local isdir = {}
  for _, d in ipairs(ents) do
    if d.mode & dat.DMDIR ~= 0 then isdir[d.qid.path] = true end
  end

  for _, d in ipairs(ents) do
    -- the root's parent is -1 and is meant to be missing
    if d.up ~= -1 and qids[d.up] == nil then
      fail[#fail + 1] = ("%s: %q has no parent (qid %d is missing)")
        :format(where, d.name, d.up)
    elseif d.up ~= -1 and not isdir[d.up] then
      fail[#fail + 1] = ("%s: %q hangs off a file rather than a directory")
        :format(where, d.name)
    end
    if d.mode & dat.DMDIR ~= 0 then
      local u = ups[d.qid.path]
      if u == nil then
        fail[#fail + 1] = ("%s: directory %q has no parent link")
          :format(where, d.name)
      elseif u.up ~= d.up or u.name ~= d.name then
        fail[#fail + 1] = ("%s: directory %q disagrees with its parent link")
          :format(where, d.name)
      end
    end
  end

  for qid, u in pairs(ups) do
    if qids[qid] == nil then
      fail[#fail + 1] = ("%s: parent link for missing qid %d (%q)")
        :format(where, qid, u.name)
    end
  end

  -- file data with no file, and data past the end of the file it claims
  local blksz = fs.geom.blksz
  local lengths = {}
  for _, d in ipairs(ents) do lengths[d.qid.path] = d.length end

  local seenq = {}
  s = fs:btscan(t, string.pack(">I1", dat.Kdat))
  for kv in s:iter() do
    local qid, off = pack.unpackdatkey(kv.k)
    local len = lengths[qid]
    if len == nil then
      if not seenq[qid] then
        seenq[qid] = true
        fail[#fail + 1] = ("%s: data blocks for missing file %d")
          :format(where, qid)
      end
    elseif off >= len then
      fail[#fail + 1] = ("%s: file %d has a block at %d, past its end of %d")
        :format(where, qid, off, len)
    end
    local bp = pack.unpackbp(kv.v)
    local ok = pcall(fs.getarena, fs, bp.addr)
    if not ok then
      fail[#fail + 1] = ("%s: file %d has a block at %d, outside every arena")
        :format(where, qid, bp.addr)
    end
  end
  s:close()
end

-- The whole volume, including the passes that need to see all of it at
-- once. Much slower than check(): it reads every reachable block and
-- walks every arena block by block.
--
-- Returns the list of complaints, and a report table. With opts.fix it
-- also returns leaked space to the free list -- but only when nothing
-- else was wrong, because the sweep that decides what is unreachable is
-- only as good as its ability to read every block, and freeing live
-- blocks because a pointer could not be followed would turn a volume
-- that mostly works into one that does not.
function Fs:fsck(opts)
  opts = opts or {}
  local fail = self:check(opts)

  for _, mnt in ipairs(self.mounts) do
    namespace(self, mnt.root, fail, "mount " .. mnt.name)
  end
  if #self.mounts == 0 then
    -- nothing mounted: check the labelled trees instead, so an fsck of a
    -- volume nobody has opened still says something about its contents
    local s = self:btscan(self.snap, string.pack(">I1", dat.Klabel))
    local names = {}
    for kv in s:iter() do names[#names + 1] = kv.k:sub(2) end
    s:close()
    for _, n in ipairs(names) do
      local ok, t = pcall(self.opensnap, self, n)
      if ok and t ~= nil then
        namespace(self, t, fail, "snap " .. n)
        self:closesnap(t)
      end
    end
  end

  local report = { leaked = {}, reclaimed = 0, structural = #fail }

  if not opts.noleaks then
    local seen = reachable(self, fail)
    -- reachable() reports blocks it could not read; a sweep that hit one
    -- has holes in it and its idea of unreachable cannot be trusted
    local blind = #fail > report.structural
    report.leaked = leaks(self, seen, opts)

    local max = opts.maxleaks or 20
    for i, l in ipairs(report.leaked) do
      if i > max then
        fail[#fail + 1] = ("%d leaked blocks in total")
          :format(#report.leaked)
        break
      end
      fail[#fail + 1] = ("leaked block at %d (arena %d)")
        :format(l.addr, l.arena)
    end

    if opts.fix and #report.leaked > 0 then
      if report.structural > 0 or blind then
        fail[#fail + 1] =
          "not reclaiming: fix only runs on a volume with nothing else wrong"
      elseif self.rdonly then
        fail[#fail + 1] = "not reclaiming: the volume is read only"
      else
        for _, l in ipairs(report.leaked) do
          self:cachedel(l.addr)
          self:blkdealloc(self.arenas[l.arena], l.addr)
        end
        report.reclaimed = #report.leaked
        -- the frees are in the log now; a commit is what makes them so
        self:sync()
      end
    end
  end
  return fail, report
end

M.reachable = reachable
M.namespace = namespace

return M
