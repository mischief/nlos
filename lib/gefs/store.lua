-- Blocks, arenas and the allocation log: gefs's blk.c and load.c.
--
-- The allocator is a per-arena free list of ranges kept in memory, with
-- an append-only log on disk that records every allocation and free. The
-- log is what makes the free list recoverable: on load it is replayed
-- from the head recorded in the arena header, and replay stops at the
-- first sync barrier at or past the generation the superblock committed,
-- so work from a generation that never committed is discarded rather
-- than half-applied.
--
-- Everything here is single-threaded. Upstream's epochs, limbo lists and
-- write queues exist to let readers run while a mutator frees blocks
-- underneath them; with one thread a block that is safe to free is safe
-- to free now, so freeing is immediate and enqueue writes through. The
-- ordering that survives is the ordering that a crash can observe, which
-- is the four passes in sync().

local dat = require "gefs.dat"
local blk = require "gefs.blk"
local pack = require "gefs.pack"
local Fs = require "gefs.obj"

local M = {}

local spack, sunpack = string.pack, string.unpack

--------------------------------------------------------------------------
-- free ranges
--
-- Upstream keeps these in an AVL tree. A sorted array with a binary
-- search has the same complexity for lookup and loses only on insertion,
-- which is a memmove of a list that stays short: gefs allocates from the
-- ends of ranges, so a healthy arena has few of them.

local function rsearch(rs, off)
  local lo, hi, r = 1, #rs, 0
  while lo <= hi do
    local mid = (lo + hi) // 2
    if rs[mid].off <= off then r = mid; lo = mid + 1 else hi = mid - 1 end
  end
  return r
end

local function freerange(rs, off, len)
  assert(len > 0, "freeing an empty range")
  local i = rsearch(rs, off)
  local prev = rs[i]
  assert(prev == nil or prev.off + prev.len <= off, "double free")
  local nxt = rs[i + 1]
  assert(nxt == nil or off + len <= nxt.off, "double free")

  table.insert(rs, i + 1, { off = off, len = len })
  local cur = i + 1
  prev = rs[cur - 1]
  if prev and prev.off + prev.len == off then
    prev.len = prev.len + len
    table.remove(rs, cur)
    cur = cur - 1
  end
  local c = rs[cur]
  nxt = rs[cur + 1]
  if nxt and c.off + c.len == nxt.off then
    c.len = c.len + nxt.len
    table.remove(rs, cur + 1)
  end
end

local function grabrange(rs, off, len)
  local i = rsearch(rs, off)
  local r = rs[i]
  assert(r ~= nil and off + len <= r.off + r.len,
    "allocating space that is not free")
  if off == r.off then
    r.off = r.off + len
    r.len = r.len - len
  elseif off + len == r.off + r.len then
    r.len = r.len - len
  else
    table.insert(rs, i + 1,
      { off = off + len, len = r.off + r.len - (off + len) })
    r.len = off - r.off
  end
  if r.len == 0 then table.remove(rs, i) end
end

M.freerange, M.grabrange, M.rsearch = freerange, grabrange, rsearch

--------------------------------------------------------------------------
-- the block cache
--
-- Only clean blocks live here. Everything this layer writes is written
-- through, so the sole dirty blocks in the system are the arena log
-- tails and the deadlist blocks being filled, and both are held by the
-- structure that owns them rather than found by address.

function Fs:cacheget(addr)
  local e = self.cache[addr]
  if e == nil then return nil end
  self.clock = self.clock + 1
  e.used = self.clock
  return e.b
end

function Fs:cacheins(b)
  if self.cmax <= 0 then return end
  if self.cache[b.bp.addr] == nil then
    self.ccount = self.ccount + 1
  end
  self.clock = self.clock + 1
  self.cache[b.bp.addr] = { b = b, used = self.clock }
  if self.ccount > self.cmax then self:cachetrim() end
end

function Fs:cachedel(addr)
  if self.cache[addr] ~= nil then
    self.cache[addr] = nil
    self.ccount = self.ccount - 1
  end
end

-- Evicting the true least-recently-used entry would want an intrusive
-- list; sampling is enough here, because the cost of a miss is one read
-- of a block that is on disk and correct either way.
function Fs:cachetrim()
  local want = self.ccount - (self.cmax * 3) // 4
  local ages = {}
  for addr, e in pairs(self.cache) do
    -- a pinned block has no copy on disk to read back, so evicting it
    -- would lose it rather than cost a read
    if not e.b.pinned then
      ages[#ages + 1] = { addr = addr, used = e.used }
    end
  end
  table.sort(ages, function(x, y) return x.used < y.used end)
  for i = 1, want do
    if ages[i] == nil then break end
    self:cachedel(ages[i].addr)
  end
end

--------------------------------------------------------------------------
-- reading and writing

function Fs:readblk(bp, flg)
  local s = self.dev:read(bp.addr, self.geom.blksz)
  if s == nil or #s ~= self.geom.blksz then
    error(("io: short read at %d"):format(bp.addr), 0)
  end
  local b, err = blk.parse(s, bp, self.geom, flg)
  if b == nil then error(err, 0) end
  b.bp.gen = bp.gen
  return b
end

function Fs:getblk(bp, flg)
  flg = flg or 0
  assert(bp.addr >= 0, "reading an unset block pointer")
  local b = self:cacheget(bp.addr)
  if b ~= nil then
    -- a cached block whose hash disagrees is a block that was freed and
    -- reused without the cache being told. Rather than trust it, drop it.
    if bp.hash == -1 or b.bp.hash == bp.hash then
      b.bp.gen = bp.gen
      return b
    end
    self:cachedel(bp.addr)
  end
  b = self:readblk(bp, flg)
  self:cacheins(b)
  return b
end

-- getblk that reports failure instead of raising, for the places that
-- have a fallback: the two arena headers, and the checker.
function Fs:tryblk(bp, flg)
  local ok, b = pcall(self.getblk, self, bp, flg)
  if ok then return b end
  return nil, b
end

-- Pack a block early, when something else has to see its hash before it
-- is written. The bytes are held until the write, so a block that is
-- finalized must not be touched again before it goes out.
function Fs:finalize(b)
  b.packed = blk.pack(b, self.geom)
  return b.packed
end

function Fs:writeblk(b)
  local s = b.packed or blk.pack(b, self.geom)
  b.packed = nil
  assert(b.bp.addr >= 0, "writing an unplaced block")
  self.dev:write(b.bp.addr, s)
  self.nwrite = self.nwrite + 1
  b.dirty = false
  return s
end

-- Upstream queues a block for a writer proc and waits at a barrier. With
-- one thread the queue is the write, and the barriers in sync() become
-- ordinary sequencing plus a device flush where the device has one.
function Fs:enqueue(b)
  self:writeblk(b)
  self:cacheins(b)
end

function Fs:devsync()
  if self.dev.sync then self.dev:sync() end
end

--------------------------------------------------------------------------
-- arenas

function Fs:getarena(addr)
  local lo, hi = 1, self.narena
  if addr == self.sb0.bp.addr then return self.arenas[1] end
  if addr == self.sb1.bp.addr then return self.arenas[self.narena] end
  while lo <= hi do
    local mid = (lo + hi) // 2
    local a = self.arenas[mid]
    if addr < a.base then
      hi = mid - 1
    elseif addr > a.base + a.size + 2 * self.geom.blksz then
      lo = mid + 1
    else
      return a
    end
  end
  error(("no arena holds %d"):format(addr), 0)
end

-- round robin across arenas, with data blocks steered away from arena 0
-- so that metadata and bulk data do not interleave on the platter
function Fs:pickarena(ty, hint, tries)
  self.roundrobin = self.roundrobin + 1
  local r = self.roundrobin // 2048
  local n
  if ty == dat.Tdat and self.narena > 1 then
    n = hint % (self.narena - 1) + r + 1
  else
    n = r
  end
  return self.arenas[(n + tries) % self.narena + 1]
end

--------------------------------------------------------------------------
-- the allocation log

local function mklogblk(fs, a, o, ty)
  local b = blk.new(ty or dat.Tlog, o, -1)
  b.logp = dat.zb()
  return b
end

-- Allocation from an arena, with no logging of its own: logappend calls
-- it to find room for the log itself, and logging that allocation is the
-- caller's job.
local function blkalloc_lk(fs, a, seq)
  if not fs.usereserve and a.size - a.used <= a.reserve then
    return -1
  end
  local rs = a.free
  local r = seq and rs[1] or rs[#rs]
  if r == nil then error("arena is stuffed", 0) end
  local b
  if seq then
    b = r.off
    r.off = r.off + fs.geom.blksz
    r.len = r.len - fs.geom.blksz
    if r.len == 0 then table.remove(rs, 1) end
  else
    r.len = r.len - fs.geom.blksz
    b = r.off + r.len
    if r.len == 0 then table.remove(rs, #rs) end
  end
  a.used = a.used + fs.geom.blksz
  return b
end

-- Append one entry to the arena's log. The op is or'ed into the low byte
-- of the offset, which is why every block address is block-aligned and
-- so has room there.
local function logappend(fs, a, off, len, op)
  assert(off & 0xff == 0, "unaligned log entry")
  assert(op == dat.LogAlloc or op == dat.LogFree or op == dat.LogSync)
  if op ~= dat.LogSync then
    assert(off >= a.base and off < a.base + a.size + 2 * fs.geom.blksz,
      "logging an address outside its arena")
  end

  local lb = a.logtl
  assert(lb ~= nil and lb.type == dat.Tlog, "arena has no open log block")
  local spill = nil
  lb.dirty = true

  -- Move to the next block when there is too little room left: this
  -- entry is up to 16 bytes, and the chaining that follows it needs 16
  -- more plus the pointer.
  if lb.logsz >= fs.geom.logspc - dat.Logslop then
    local o = blkalloc_lk(fs, a, false)
    if o == -1 then error("filesystem is full", 0) end
    lb.logents[#lb.logents + 1] = spack(">i8", o | dat.LogAlloc1)
    lb.logsz = lb.logsz + 8
    lb.logp = { addr = o, hash = -1, gen = -1 }
    spill = mklogblk(fs, a, o)
    lb = spill
  end

  if len == fs.geom.blksz then
    if op == dat.LogAlloc then op = dat.LogAlloc1
    elseif op == dat.LogFree then op = dat.LogFree1 end
  end

  lb.logents[#lb.logents + 1] = spack(">i8", off | op)
  lb.logsz = lb.logsz + 8
  lb.dirty = true
  if op >= dat.Log2wide then
    lb.logents[#lb.logents + 1] = spack(">i8", len)
    lb.logsz = lb.logsz + 8
  end

  if spill ~= nil then
    -- the new block first, then the old tail that now chains to it: a
    -- crash between them loses an entry rather than following a pointer
    -- to a block that was never written
    fs:writeblk(spill)
    fs:writeblk(a.logtl)
    fs:cachedel(a.logtl.bp.addr)
    a.logtl = spill
    a.nlog = a.nlog + 1
  end
end

function Fs:logbarrier(a, gen)
  logappend(self, a, gen << 8, 0, dat.LogSync)
end

function Fs:flushlog(a)
  if not a.logtl.dirty then return end
  self:writeblk(a.logtl)
  self:cachedel(a.logtl.bp.addr)
end

function Fs:loadlog(a, bp)
  local b
  while true do
    b = self:readblk(bp, 0)
    a.nlog = a.nlog + 1
    local i = 0
    local n = #b.logents
    local j = 1
    while j <= n do
      local ent = sunpack(">i8", b.logents[j])
      local op = ent & 0xff
      local off = ent & ~0xff
      local wide = op >= dat.Log2wide
      local len
      if op == dat.LogSync then
        local gen = ent >> 8
        if gen >= self.qgen then
          -- Everything past this barrier belongs to a generation that
          -- never reached the superblock. Truncate here and reopen the
          -- log at this point.
          b.logp = dat.zb()
          b.logsz = i
          for k = #b.logents, j, -1 do b.logents[k] = nil end
          b.dirty = true
          a.logtl = b
          self:cachedel(b.bp.addr)
          return
        end
      elseif op == dat.LogAlloc or op == dat.LogAlloc1 then
        len = wide and sunpack(">i8", b.logents[j + 1]) or self.geom.blksz
        grabrange(a.free, off, len)
        a.used = a.used + len
      elseif op == dat.LogFree or op == dat.LogFree1 then
        len = wide and sunpack(">i8", b.logents[j + 1]) or self.geom.blksz
        freerange(a.free, off, len)
        a.used = a.used - len
      else
        error(("unknown log op %d at %d+%d"):format(op, bp.addr, i), 0)
      end
      local step = wide and 16 or 8
      i = i + step
      j = j + (step // 8)
    end
    if b.logp.addr == -1 then
      b.dirty = false
      a.logtl = b
      self:cachedel(b.bp.addr)
      return
    end
    bp = b.logp
  end
end

-- Rewrite the log as nothing but the free list it implies. An arena has
-- to be sized so the merged log fits in memory for this, which upstream
-- notes and this inherits.
function Fs:compresslog(a)
  self:flushlog(a)

  local nr = #a.free
  local sz = 16 * nr
  local logspc = self.geom.logspc

  -- pessimistic: room for the ranges, plus room for the frees that
  -- allocating those blocks will themselves log
  local nblks = (sz + logspc) // (logspc - dat.Logslop)
    + (16 * nr) // (logspc - dat.Logslop) + 1
  local blks = {}
  for i = 1, nblks do
    blks[i] = blkalloc_lk(self, a, true)
    if blks[i] == -1 then error("filesystem is full", 0) end
  end

  local i = 1
  local b = mklogblk(self, a, blks[i]); i = i + 1
  for _, r in ipairs(a.free) do
    if b.logsz >= logspc - dat.Logslop then
      b.logp = { addr = blks[i], hash = -1, gen = -1 }
      self:writeblk(b)
      b = mklogblk(self, a, blks[i]); i = i + 1
    end
    b.logents[#b.logents + 1] = spack(">i8", r.off | dat.LogFree)
    b.logents[#b.logents + 1] = spack(">i8", r.len)
    b.logsz = b.logsz + 16
  end
  self:writeblk(b)

  -- The new log is valid from here, so the leftover blocks can be given
  -- back through it. The old tail's reference goes first: deallocating
  -- may need to append, and appending must land in the new log.
  self:cachedel(a.logtl.bp.addr)
  a.loghd = { addr = blks[1], hash = -1, gen = -1 }
  a.logtl = b
  a.nlog = i - 1
  a.lastlogsz = a.nlog

  for k = i, nblks do
    self:blkdealloc(a, blks[k])
  end
end

function Fs:blkdealloc(a, addr)
  self:cachedel(addr)
  logappend(self, a, addr, self.geom.blksz, dat.LogFree)
  freerange(a.free, addr, self.geom.blksz)
  a.used = a.used - self.geom.blksz
end

-- Pick an arena and take a block from it. seq asks for the low end of
-- the lowest range rather than the high end of the highest, which is
-- what keeps a file's blocks near each other as it is appended to.
function Fs:blkalloc(ty, hint, seq)
  local tries = 0
  while true do
    if tries >= 2 * self.narena then error("filesystem is full", 0) end
    local a = self:pickarena(ty, hint or 0, tries)
    tries = tries + 1
    local b = blkalloc_lk(self, a, seq)
    if b ~= -1 then
      logappend(self, a, b, self.geom.blksz, dat.LogAlloc)
      return b
    end
  end
end

--------------------------------------------------------------------------
-- new blocks
--
-- A block is born into the tree's memgen. That generation is what
-- decides, later, whether freeing it can return it to the free list at
-- once or has to go through a snapshot's deadlist.

function Fs:newblk(t, ty)
  local addr = self:blkalloc(ty, 0, false)
  self:cachedel(addr)
  return blk.new(ty, addr, t and t.memgen or -1)
end

function Fs:newdblk(t, hint, seq)
  local addr = self:blkalloc(dat.Tdat, hint, seq)
  self:cachedel(addr)
  return blk.new(dat.Tdat, addr, t and t.memgen or -1)
end

--------------------------------------------------------------------------
-- freeing
--
-- A block born before the tree's current generation may still be
-- reachable from a snapshot, so it is recorded in that snapshot's
-- deadlist and reclaimed when the snapshot goes. A block born in this
-- generation is not on disk anywhere that a crash could observe, so it
-- goes straight back to the arena.

function Fs:freebp(t, bp)
  if bp.addr == -1 then return end
  if t == self.snap or (t ~= nil and bp.gen < t.memgen) then
    self:killblk(t, bp)
    return
  end
  self:cachedel(bp.addr)
  local a = self:getarena(bp.addr)
  self:blkdealloc(a, bp.addr)
end

function Fs:freeblk(t, b)
  if b == nil then return end
  self:freebp(t, b.bp)
end

return M
