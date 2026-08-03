-- The Bε-tree: gefs's tree.c.
--
-- A pivot node carries a buffer of messages alongside its pointers. An
-- update is a message appended to the root's buffer; when a buffer
-- fills, the largest contiguous run of messages destined for one child
-- is pushed down into it, and only at a leaf does a message meet the
-- value it modifies. That is the whole idea: a write costs one block
-- touched near the root instead of one per level, and the cost of the
-- descent is paid once for a whole batch rather than once per key.
--
-- Everything a node needs is decided from the node itself. A flush picks
-- its victim child by which run of messages is biggest, splits when the
-- node would not fit its own guarantee, and merges or rotates with a
-- sibling when a node has drained. Those decisions are ported exactly,
-- because a tree that is merely valid but differently shaped is a tree
-- whose full-disk behaviour no test would reach.
--
-- Indices here are 0-based, matching the C. The block accessors below
-- do the translation once, so nothing else has to think about it.

local dat = require "gefs.dat"
local blkmod = require "gefs.blk"
local pack = require "gefs.pack"
local Fs = require "gefs.obj"

local M = {}

local keycmp = blkmod.keycmp
local msgsz = blkmod.msgsz
local valsz = blkmod.valsz
local spack, sunpack = string.pack, string.unpack

-- path ops, recording what happened to a node so its parent knows what
-- to write in its place
local POmod = 0
local POrot = 1
local POsplit = 2
local POmerge = 3

--------------------------------------------------------------------------
-- 0-based views of a block's two regions

local function nval(b) return #b.vals end
local function nbuf(b) return #b.msgs end
local function getval(b, i) return b.vals[i + 1] end
local function getmsg(b, i) return b.msgs[i + 1] end

--------------------------------------------------------------------------
-- searching within a node
--
-- Both searches return the index of the last entry at or before the key,
-- and -1 when the key sorts before everything. When the key is present
-- they return its first occurrence, because a run of equal keys is a run
-- of messages in arrival order and the oldest has to be applied first.

local function bufsearch(b, k)
  local ri, lo, hi = -1, 0, nbuf(b) - 1
  while lo <= hi do
    local mid = (hi + lo) // 2
    local r = keycmp(k, getmsg(b, mid).k)
    if r < 0 then hi = mid - 1
    elseif r == 0 then ri = mid; hi = mid - 1
    else lo = mid + 1 end
  end
  local same = ri ~= -1
  if ri == -1 then ri = lo - 1 end
  return ri, same
end

local function blksearch(b, k)
  local ri, lo, hi = -1, 0, nval(b) - 1
  while lo <= hi do
    local mid = (hi + lo) // 2
    local r = keycmp(k, getval(b, mid).k)
    if r < 0 then hi = mid - 1
    elseif r == 0 then ri = mid; hi = mid - 1
    else lo = mid + 1 end
  end
  local same = ri ~= -1
  if ri == -1 then ri = lo - 1 end
  return ri, same
end

M.bufsearch, M.blksearch = bufsearch, blksearch

--------------------------------------------------------------------------
-- applying a message to a value

local function statupdate(kv, m)
  assert(#m.v >= 1, "empty wstat")
  local d = pack.unpackdval(kv.v)
  local op = m.v:byte(1)
  local p = 2

  d.qid.vers = (d.qid.vers + 1) & 0xffffffff

  if op & dat.Owsize ~= 0 then d.length = sunpack(">i8", m.v, p); p = p + 8 end
  if op & dat.Owmode ~= 0 then
    d.mode = sunpack(">I4", m.v, p); p = p + 4
    d.qid.type = d.mode >> 24
  end
  if op & dat.Owmtime ~= 0 then d.mtime = sunpack(">i8", m.v, p); p = p + 8 end
  if op & dat.Owatime ~= 0 then d.atime = sunpack(">i8", m.v, p); p = p + 8 end
  if op & dat.Owuid ~= 0 then d.uid = sunpack(">i4", m.v, p); p = p + 4 end
  if op & dat.Owgid ~= 0 then d.gid = sunpack(">i4", m.v, p); p = p + 4 end
  if op & dat.Owmuid ~= 0 then d.muid = sunpack(">i4", m.v, p); p = p + 4 end
  assert(p == #m.v + 1, "malformed wstat")

  return pack.packdval(d)
end

-- Returns whether a value survives, and the value. A delete leaves the
-- old value in place and only reports that it is gone, because a later
-- message in the same run may bring it back.
local function apply(kv, m)
  local op = m.op
  if op == dat.Odelete then
    assert(keycmp(kv.k, m.k) == 0, "delete of the wrong key")
    return false, kv
  elseif op == dat.Oclearb or op == dat.Oclobber then
    return false, kv
  elseif op == dat.Oinsert then
    return true, { k = m.k, v = m.v }
  elseif op == dat.Owstat then
    assert(keycmp(kv.k, m.k) == 0, "wstat of the wrong key")
    return true, { k = kv.k, v = statupdate(kv, m) }
  elseif op == dat.Orelink or op == dat.Oreprev or op == dat.Oincref then
    local t = pack.unpacktree(kv.v)
    local link, dlbl, dref = pack.unpackretag(m.v)
    if op == dat.Orelink then t.succ = link
    elseif op == dat.Oreprev then t.pred = link end
    t.nlbl = t.nlbl + dlbl
    t.nref = t.nref + dref
    assert(t.nlbl >= 0 and t.nref >= 0, "snapshot refcount went negative")
    return true, { k = kv.k, v = pack.packtree(t) }
  end
  error("invalid message op " .. tostring(op), 0)
end

M.apply = apply

--------------------------------------------------------------------------
-- lookup
--
-- Descend to the leaf collecting the value, then walk back up applying
-- every buffered message that names the key. Messages nearer the root
-- are newer, so the ascent is the order they must be applied in.

function Fs:btlookup(t, k)
  local h = t.ht
  local b = self:getblk(t.bp, 0)
  local p = { [0] = b }
  local r, ok = nil, false

  for i = 1, h - 1 do
    local idx = blksearch(p[i - 1], k)
    if idx == -1 then break end
    r = getval(p[i - 1], idx)
    p[i] = self:getblk(pack.unpackbp(r.v), 0)
  end

  if p[h - 1] ~= nil then
    local idx, same = blksearch(p[h - 1], k)
    if idx ~= -1 then r = getval(p[h - 1], idx) end
    ok = same
  end

  for i = h - 2, 0, -1 do
    if p[i] ~= nil then
      local j, same = bufsearch(p[i], k)
      if j >= 0 and same then
        local m = getmsg(p[i], j)
        if ok or m.op == dat.Oinsert then
          ok, r = apply(r, m)
        elseif m.op ~= dat.Oclearb and m.op ~= dat.Oclobber then
          error(("lookup of %q met %s with no insert")
            :format(k, dat.opname[m.op] or m.op), 0)
        end
        j = j + 1
        while j < nbuf(p[i]) do
          m = getmsg(p[i], j)
          if keycmp(k, m.k) ~= 0 then break end
          ok, r = apply(r, m)
          j = j + 1
        end
      end
    end
  end

  if not ok then return nil end
  return r
end

--------------------------------------------------------------------------
-- scanning
--
-- The same merge as lookup, run as an iterator: at every step the
-- candidate is the smallest of the leaf's next value and each level's
-- next message, and messages from higher levels win ties.

local Scan = {}
Scan.__index = Scan

function Fs:btscan(t, pfx)
  local s = setmetatable({
    fs = self, t = t, pfx = pfx or "",
    first = true, done = false, ht = t.ht, path = {},
  }, Scan)
  s:enter()
  return s
end

function Scan:enter()
  if self.done then return end
  local fs, p = self.fs, self.path
  local b = fs:getblk(self.t.bp, 0)
  self.ht = self.t.ht
  local key = self.pfx

  p[0] = { b = b, vi = 0, bi = 0 }
  for i = 0, self.ht - 1 do
    local same
    p[i].vi, same = blksearch(b, key)
    if b.type == dat.Tpivot then
      if p[i].vi == -1 then p[i].vi = 0 end
      local v = getval(b, p[i].vi)
      local m
      p[i].bi, same = bufsearch(b, key)
      if p[i].bi == -1 then
        p[i].bi = 0
      elseif not same or not self.first then
        -- step past a run of messages we have already reported
        m = getmsg(b, p[i].bi)
        while p[i].bi < nbuf(b) do
          local c = getmsg(b, p[i].bi)
          if keycmp(m.k, c.k) ~= 0 then break end
          p[i].bi = p[i].bi + 1
        end
      end
      b = fs:getblk(pack.unpackbp(v.v), 0)
      p[i + 1] = { b = b, vi = 0, bi = 0 }
    elseif p[i].vi == -1 or not same or not self.first then
      p[i].vi = p[i].vi + 1
    end
  end
  self.first = false
end

function Scan:next()
  while true do
    local p, h = self.path, self.ht
    if self.done or p[0] == nil then return nil end

    local start = h
    local bufsrc = -1

    -- unwind levels that are exhausted, advancing the parent as we go
    local i = h - 1
    while i >= 0 do
      local e = p[i]
      if e.b ~= nil and (e.vi < nval(e.b) or e.bi < nbuf(e.b)) then break end
      if i == 0 then self.done = true; return nil end
      e.b = nil; e.vi = 0; e.bi = 0
      p[i - 1].vi = p[i - 1].vi + 1
      start = i
      i = i - 1
    end

    local ok, m
    if p[start - 1].vi < nval(p[start - 1].b) then
      for j = start, h - 1 do
        local kv = getval(p[j - 1].b, p[j - 1].vi)
        p[j].b = self.fs:getblk(pack.unpackbp(kv.v), 0)
      end
      ok = true
      local kv = getval(p[h - 1].b, p[h - 1].vi)
      m = { op = dat.Oinsert, k = kv.k, v = kv.v }
    else
      m = getmsg(p[start - 1].b, p[start - 1].bi)
      if m.op == dat.Oinsert then ok = true
      elseif m.op == dat.Oclobber or m.op == dat.Oclearb then ok = false
      else error("broken scan entry: " .. tostring(dat.opname[m.op]), 0) end
      bufsrc = start - 1
    end

    for j = h - 2, 0, -1 do
      local e = p[j]
      if e.b ~= nil and e.bi ~= nbuf(e.b) then
        local n = getmsg(e.b, e.bi)
        if keycmp(n.k, m.k) < 0 then
          if n.op == dat.Oinsert then ok = true
          elseif n.op == dat.Oclobber or n.op == dat.Oclearb then ok = false
          else error("broken scan entry: " .. tostring(dat.opname[n.op]), 0) end
          bufsrc = j
          m = n
        end
      end
    end

    if #m.k < #self.pfx or m.k:sub(1, #self.pfx) ~= self.pfx then
      self.done = true
      return nil
    end

    local r = { k = m.k, v = m.v }
    if bufsrc == -1 then
      p[h - 1].vi = p[h - 1].vi + 1
    else
      p[bufsrc].bi = p[bufsrc].bi + 1
    end

    for j = h - 2, 0, -1 do
      local e = p[j]
      while e.b ~= nil and e.bi < nbuf(e.b) do
        local n = getmsg(e.b, e.bi)
        if keycmp(r.k, n.k) ~= 0 then break end
        ok, r = apply(r, n)
        e.bi = e.bi + 1
      end
    end

    if ok then return r end
  end
end

function Scan:close()
  self.path = {}
  self.ht = 0
end

-- for _, kv in scan:iter() do ... end
function Scan:iter()
  return function() return self:next() end
end

--------------------------------------------------------------------------
-- rebuilding nodes
--
-- Every one of these builds a fresh block rather than editing the old
-- one: that is the copy-on-write, and it is what makes a snapshot free.

local function setb(fs, p, field, t, b)
  if p[field] ~= nil then fs:freeblk(t, p[field]) end
  if nval(b) == 0 then
    fs:freeblk(t, b)
    p[field] = nil
  else
    fs:enqueue(b)
    p[field] = b
  end
end

-- The separator for a child is the smallest key it holds, which may be
-- in its buffer rather than among its values: a message for a key that
-- does not exist yet still has to route to the same child.
local function copyup(fs, n, pp)
  local nbytes = 0
  for _, side in ipairs({ "nl", "nr" }) do
    local c = pp[side]
    if c ~= nil then
      local kv = getval(c, 0)
      local k = kv.k
      if nbuf(c) > 0 then
        local m = getmsg(c, 0)
        if keycmp(k, m.k) > 0 then k = m.k end
      end
      n:setptr(k, c.bp, c:fill(), fs.geom)
      nbytes = nbytes + 2 + 2 + #k + 2 + dat.Pptrsz
    end
  end
  return nbytes
end

-- The next message flowing down, if it fits. Reports 'full' when it does
-- not, which stops the caller pulling rather than stopping it copying.
local function pullmsg(p, i, vkey, full, spc)
  if i < 0 or i >= p.hi or full then return -1, nil, full end
  local m
  if p.ins ~= nil then m = p.ins[i + 1] else m = getmsg(p.b, i) end
  if msgsz(m) <= spc then
    if vkey == nil then return 0, m, full end
    return keycmp(vkey, m.k), m, full
  end
  return -1, m, true
end

-- Is this a data key whose old block the incoming message orphans?
local function orphans(v, m)
  if #v.k == 0 or v.k:byte(1) ~= dat.Kdat then return false end
  return m.op == dat.Oclearb or m.op == dat.Oinsert or m.op == dat.Odelete
end

local function updateleaf(fs, t, up, p)
  local b = p.b
  local i, j = 0, up.lo
  local full = false
  -- Conservative on purpose: deletions take no room in a leaf, but the
  -- types of the messages still upstream are not known here.
  local spc = fs.geom.leafspc - b:fill()
  local n = fs:newblk(t, b.type)

  -- m outlives one turn of the loop on purpose. Once the leaf's own
  -- values run out there is nothing left to compare against and the
  -- message to insert is the one the last comparison, or the last
  -- pullmsg, already fetched for this j.
  local v, m
  while i < nval(b) or j < up.hi do
    local c
    if i >= nval(b) then
      c = 1
    else
      c = -1
      v = getval(b, i)
      if j < up.hi then
        m = (up.ins ~= nil) and up.ins[j + 1] or getmsg(up.b, j)
        if msgsz(m) <= spc then c = keycmp(v.k, m.k) else full = true end
      end
    end

    if c == -1 then
      i = i + 1
      n:setval(v, fs.geom)
    else
      local ok
      if c == 0 then
        i = i + 1; j = j + 1
        if orphans(v, m) then fs:freebp(t, pack.unpackbp(v.v)) end
        ok, v = apply(v, m)
      else
        j = j + 1
        v = { k = m.k, v = m.v }
        ok = false
        if m.op ~= dat.Oclearb and m.op ~= dat.Oclobber then
          if m.op ~= dat.Oinsert then
            error("broken entry: " .. tostring(dat.opname[m.op]), 0)
          end
          spc = spc - valsz(m)
          p.pullsz = p.pullsz + msgsz(m)
          ok = true
        end
      end
      while j < up.hi do
        local r
        r, m, full = pullmsg(up, j, v.k, full, spc)
        if r ~= 0 then break end
        assert(not full)
        if ok and orphans(v, m) then fs:freebp(t, pack.unpackbp(v.v)) end
        p.pullsz = p.pullsz + msgsz(m)
        ok, v = apply(v, m)
        j = j + 1
      end
      if ok then n:setval(v, fs.geom) end
    end
  end

  p.npull = j - up.lo
  p.op = POmod
  setb(fs, p, "nl", t, n)
end

local function updatepiv(fs, t, up, p, pp)
  local b = p.b
  local n = fs:newblk(t, b.type)

  local i = 0
  while i < nval(b) do
    if pp ~= nil and i == p.midx then
      copyup(fs, n, pp)
      if pp.op == POrot or pp.op == POmerge then i = i + 1 end
    else
      n:setval(getval(b, i), fs.geom)
    end
    i = i + 1
  end

  i = 0
  local j = up.lo
  local sz = 0
  local full = false
  -- room for incoming messages: what this node has free, plus what the
  -- child just took off its hands
  local spc = fs.geom.bufspc - b:buffill()
  if pp ~= nil then spc = spc + pp.pullsz end

  while i < nbuf(b) do
    if i == p.lo then i = i + pp.npull end
    if i >= nbuf(b) then break end
    local m = getmsg(b, i)
    local r, u
    r, u, full = pullmsg(up, j, m.k, full, spc - sz)
    if r == -1 or r == 0 then
      n:setmsg(m, fs.geom)
      i = i + 1
    else
      -- the incoming message sorts first: drain the whole run of them
      local key = u.k
      while true do
        local rr
        rr, u, full = pullmsg(up, j, key, full, spc)
        if rr ~= 0 then break end
        n:setmsg(u, fs.geom)
        sz = msgsz(u)
        p.pullsz = p.pullsz + sz
        spc = spc - sz
        j = j + 1
      end
    end
  end

  while j < up.hi do
    local _, u
    _, u, full = pullmsg(up, j, nil, full, spc)
    if full then break end
    n:setmsg(u, fs.geom)
    sz = msgsz(u)
    p.pullsz = p.pullsz + sz
    spc = spc - sz
    j = j + 1
  end

  p.npull = j - up.lo
  p.op = POmod
  setb(fs, p, "nl", t, n)
end

--------------------------------------------------------------------------
-- splitting
--
-- A split must never grow the tree by more than one level, and must
-- leave at least two entries on each side or the result is not a valid
-- interior node.

local function splitleaf(fs, t, up, p)
  local b = p.b
  local l = fs:newblk(t, b.type)
  local r = fs:newblk(t, b.type)
  local leafspc = fs.geom.leafspc

  local d = l
  local i, j = 0, up.lo
  local full = false
  local copied = 0
  local halfsz = (2 * nval(b) + b.valsz + up.sz) // 2
  if halfsz > leafspc // 2 then halfsz = leafspc // 2 end
  local spc = leafspc - (halfsz + dat.Msgmax)
  assert(nval(b) >= 4, "splitting a leaf with too little in it")

  while i < nval(b) do
    if d == l and ((i == nval(b) - 2) or (i >= 2 and copied >= halfsz)) then
      d = r
      spc = leafspc - (halfsz + dat.Msgmax)
    end
    local v = getval(b, i)
    local c, m
    c, m, full = pullmsg(up, j, v.k, full, spc)

    if c == -1 then
      i = i + 1
      d:setval(v, fs.geom)
      copied = copied + valsz(v)
    else
      local ok
      if c == 0 then
        i = i + 1; j = j + 1
        copied = copied + valsz(v)
        if orphans(v, m) then fs:freebp(t, pack.unpackbp(v.v)) end
        ok, v = apply(v, m)
      else
        j = j + 1
        v = { k = m.k, v = m.v }
        copied = copied + valsz(v)
        ok = false
        if m.op ~= dat.Oclearb and m.op ~= dat.Oclobber then
          if m.op ~= dat.Oinsert then
            error("broken entry: " .. tostring(dat.opname[m.op]), 0)
          end
          spc = spc - valsz(m)
          p.pullsz = p.pullsz + msgsz(m)
          ok = true
        end
      end
      while j < up.hi do
        local rr
        rr, m, full = pullmsg(up, j, v.k, full, spc)
        if rr ~= 0 then break end
        if ok and orphans(v, m) then fs:freebp(t, pack.unpackbp(v.v)) end
        p.pullsz = p.pullsz + msgsz(m)
        ok, v = apply(v, m)
        j = j + 1
      end
      if ok then d:setval(v, fs.geom) end
    end
  end

  p.npull = j - up.lo
  p.op = POsplit
  setb(fs, p, "nl", t, l)
  setb(fs, p, "nr", t, r)
end

local function splitpiv(fs, t, _up, p, pp)
  local b = p.b
  local l = fs:newblk(t, b.type)
  local r = fs:newblk(t, b.type)

  local d = l
  local copied = 0
  local halfsz = (2 * nval(b) + b.valsz) // 2
  assert(nval(b) >= 4, "splitting a pivot with too little in it")

  for i = 0, nval(b) - 1 do
    if d == l and (i == nval(b) - 2 or (i >= 2 and copied >= halfsz)) then
      d = r
    end
    if i == p.idx then
      copied = copied + copyup(fs, d, pp)
    else
      local kv = getval(b, i)
      d:setval(kv, fs.geom)
      copied = copied + valsz(kv)
    end
  end

  d = l
  local mid = getval(r, 0)
  local i = 0
  while i < nbuf(b) do
    if i == p.lo then i = i + pp.npull end
    if i >= nbuf(b) then break end
    local m = getmsg(b, i)
    if d == l and keycmp(m.k, mid.k) >= 0 then d = r end
    d:setmsg(m, fs.geom)
    i = i + 1
  end

  p.op = POsplit
  setb(fs, p, "nl", t, l)
  setb(fs, p, "nr", t, r)
end

--------------------------------------------------------------------------
-- merging and rotating
--
-- A node that has drained is folded back into a sibling, or, when the
-- pair is too big to fold, rebalanced between them. Either way the
-- parent hears about it through pp->op and rewrites one or two pointers.

local function merge(fs, t, p, pp, idx, a, b)
  local d = fs:newblk(t, a.type)
  for i = 0, nval(a) - 1 do d:setval(getval(a, i), fs.geom) end
  for i = 0, nval(b) - 1 do d:setval(getval(b, i), fs.geom) end
  if a.type == dat.Tpivot then
    for i = 0, nbuf(a) - 1 do d:setmsg(getmsg(a, i), fs.geom) end
    for i = 0, nbuf(b) - 1 do d:setmsg(getmsg(b, i), fs.geom) end
  end
  p.midx = idx
  pp.op = POmerge
  setb(fs, pp, "nl", t, d)
end

-- The first message in the pair's buffers at or after m: the point the
-- buffers have to be cut so each message stays with the values it
-- applies to.
local function splitidx(l, r, m, idx)
  if l.type == dat.Tleaf then return idx end
  local i = idx
  while i < nbuf(l) + nbuf(r) do
    local n = (i < nbuf(l)) and getmsg(l, i) or getmsg(r, i - nbuf(l))
    if keycmp(m.k, n.k) <= 0 then break end
    i = i + 1
  end
  return i
end

local function rotate(fs, t, p, pp, midx, a, b, halfpiv)
  local l = fs:newblk(t, a.type)
  local r = fs:newblk(t, a.type)

  local d = l
  local sz, sp = 0, 0
  for _, src in ipairs({ a, b }) do
    for i = 0, nval(src) - 1 do
      local m = getval(src, i)
      if d == l then
        sp = splitidx(a, b, m, sp)
        if sz >= halfpiv then d = r end
      end
      d:setval(m, fs.geom)
      sz = sz + valsz(m)
    end
  end

  if a.type == dat.Tpivot then
    d = l
    local o = 0
    for _, src in ipairs({ a, b }) do
      for i = 0, nbuf(src) - 1 do
        if o == sp then d = r; o = 0 end
        d:setmsg(getmsg(src, i), fs.geom)
        o = o + 1
      end
    end
  end

  p.midx = midx
  pp.op = POrot
  setb(fs, pp, "nl", t, l)
  setb(fs, pp, "nr", t, r)
end

local function rotmerge(fs, t, p, pp, idx, a, b)
  assert(a.type == b.type, "merging unlike blocks")
  local na = 2 * nval(a) + a.valsz
  local nb = 2 * nval(b) + b.valsz
  local ma, mb = 0, 0
  if a.type ~= dat.Tleaf then
    ma = 2 * nbuf(a) + a.bufsz
    mb = 2 * nbuf(b) + b.bufsz
  end
  local imbalance = na - nb
  if imbalance < 0 then imbalance = -imbalance end

  -- the leaf case falls out: 0 is always below bufspc
  if na + nb < (fs.geom.pivspc - 4 * dat.Msgmax) and ma + mb < fs.geom.bufspc then
    merge(fs, t, p, pp, idx, a, b)
    return true
  elseif imbalance > 4 * dat.Msgmax then
    rotate(fs, t, p, pp, idx, a, b, (na + nb) // 2)
    return true
  end
  return false
end

local function trybalance(fs, t, p, pp, idx)
  if p.idx == -1 or pp == nil or pp.nl == nil then return end
  if pp.op ~= POmod and pp.op ~= POmerge then return end

  local m = pp.nl
  local spc = (m.type == dat.Tleaf) and fs.geom.leafspc or fs.geom.pivspc

  if idx - 1 >= 0 then
    local kl = getval(p.b, idx - 1)
    local bp, fill = blkmod.getptr(kl)
    if fill + m:fill() < spc then
      local l = fs:getblk(bp, 0)
      if rotmerge(fs, t, p, pp, idx - 1, l, m) then p.s = l end
      return
    end
  end
  if idx + 1 < nval(p.b) then
    local kr = getval(p.b, idx + 1)
    local bp, fill = blkmod.getptr(kr)
    if fill + m:fill() < spc then
      local r = fs:getblk(bp, 0)
      if rotmerge(fs, t, p, pp, idx, m, r) then p.s = r end
      return
    end
  end
end

--------------------------------------------------------------------------
-- the flush itself
--
-- Walks back up the path that btupsert descended, rebuilding each node
-- with the messages that flowed into it. path[0] is a sentinel holding
-- the caller's messages on the way down and the new root on the way up.

local function flush(fs, t, path, npath)
  assert(npath >= 2, "a flush needs a node and a place to put a new root")
  local rp = nil
  local pp = nil
  local pi = npath - 1
  local ui = npath - 2
  local p = path[pi]
  local up = path[ui]

  if p.b.type == dat.Tleaf then
    if not p.b:filledleaf(up.sz, fs.geom) then
      updateleaf(fs, t, path[pi - 1], p)
      rp = p
    else
      splitleaf(fs, t, up, p)
    end
    p.midx = -1
    pp = p
    ui = ui - 1
    pi = pi - 1
    p = path[pi]
    up = path[ui]
  end

  while pi ~= 0 do
    -- One key is added at most, but a child can be replaced by a bigger
    -- one, so this splits earlier than the immediate need suggests.
    if not p.b:filledpiv(2, fs.geom) then
      trybalance(fs, t, p, pp, p.idx)

      -- The root merged and its buffer came down whole: the child is the
      -- tree now. If the buffer did not come down whole, the caller
      -- retries against the degenerate root that is left.
      if ui == 0 and pp ~= nil and pp.nl ~= nil and pp.nr == nil
        and pp.npull == nbuf(p.b) then
        if (pp.op == POmerge and nval(p.b) == 2)
          or (pp.op == POmod and nval(p.b) == 1) then
          pp.npull = p.npull
          return pp
        end
      end

      updatepiv(fs, t, up, p, pp)
      rp = p
    else
      splitpiv(fs, t, up, p, pp)
    end
    pp = p
    ui = ui - 1
    pi = pi - 1
    p = path[pi]
    up = path[ui]
  end

  if pp.nl ~= nil and pp.nr ~= nil then
    rp = path[0]
    rp.nl = fs:newblk(t, dat.Tpivot)
    rp.npull = pp.npull
    rp.pullsz = pp.pullsz
    copyup(fs, rp.nl, pp)
    fs:enqueue(rp.nl)
  end
  return rp
end

local function freepath(fs, t, path, npath, ok)
  for i = 0, npath - 1 do
    local p = path[i]
    if ok then
      if p.b then fs:freeblk(t, p.b) end
      if p.s then fs:freeblk(t, p.s) end
    end
  end
end

--------------------------------------------------------------------------
-- picking where to flush
--
-- The child with the largest run of messages waiting for it, because
-- that is the one where a descent moves the most work per block touched.

local function victim(b, p)
  local j = 0
  local maxsz = 0
  p.b = b
  -- Start at the second pivot: everything at or below the first goes to
  -- the first child. Stop after the last, since everything at or above
  -- it goes to the last child.
  for i = 1, nval(b) do
    local kv = (i < nval(b)) and getval(b, i) or nil
    local cursz = 0
    local lo = j
    while j < nbuf(b) do
      local m = getmsg(b, j)
      if kv ~= nil and keycmp(m.k, kv.k) >= 0 then break end
      cursz = cursz + msgsz(m)
      j = j + 1
    end
    if cursz > maxsz then
      maxsz = cursz
      p.op = POmod
      p.lo = lo
      p.hi = j
      p.sz = maxsz
      p.idx = i - 1
      p.midx = i - 1
      p.npull = 0
      p.pullsz = 0
    end
  end
end

--------------------------------------------------------------------------
-- the fast path
--
-- When the root's buffer has room, an update is one block: shadow the
-- root, drop the messages into its buffer in key order, done. No descent
-- happens at all. This is the case that makes a Bε-tree cheap.

local function fastupsert(fs, t, b, msg)
  local r = fs:newblk(t, b.type)
  blkmod.copy(r, b)

  for _, m in ipairs(msg) do
    -- find the position after the last message with an equal key, so a
    -- run stays in arrival order
    local ri, lo, hi = -1, 0, nbuf(r) - 1
    while lo <= hi do
      local mid = (hi + lo) // 2
      local c = keycmp(m.k, getmsg(r, mid).k)
      if c < 0 then hi = mid - 1
      elseif c == 0 then ri = mid + 1; lo = mid + 1
      else lo = mid + 1 end
    end
    if ri == -1 then ri = hi + 1 end
    r:insmsg(ri + 1, m, fs.geom)
  end

  fs:enqueue(r)
  t.bp = r.bp
  t.dirty = true
  fs:freeblk(t, b)
end

--------------------------------------------------------------------------
-- upsert

local function stablesort(msg)
  for i = 2, #msg do
    local j = i
    while j > 1 and keycmp(msg[j - 1].k, msg[j].k) > 0 do
      msg[j - 1], msg[j] = msg[j], msg[j - 1]
      j = j - 1
    end
  end
end

M.stablesort = stablesort

-- Apply a batch of messages. They are sorted stably first, so equal keys
-- keep the order the caller gave them, which is the order they will be
-- applied in.
--
-- One contract the tree does not check on the way in and does raise on
-- the way down: a delete is only legal for a key that exists. Nothing
-- lower can tell "gone" from "never here", so the caller has to have
-- looked. Oclearb is the op that is allowed to miss, and is what a file
-- with holes uses.
function Fs:btupsert(t, msg)
  local nmsg = #msg
  if nmsg == 0 then return end

  local sz = 0
  stablesort(msg)
  for _, m in ipairs(msg) do
    assert(#m.k <= dat.Keymax, "key too long")
    assert(#m.v <= dat.Inlmax, "inline value too long")
    sz = sz + msgsz(m)
  end

  local npull = 0
  while true do
    local b = self:getblk(t.bp, 0)
    local height = t.ht

    if npull == 0 and b.type == dat.Tpivot and nval(b) > 1
      and not b:filledbuf(nmsg, sz, self.geom) then
      fastupsert(self, t, b, msg)
      return
    end

    -- room for one more level than the tree has, since a split at the
    -- root grows it by one
    local path = {}
    for i = 0, height + 1 do
      path[i] = { idx = -1, midx = -1, lo = -1, hi = -1,
                  npull = 0, pullsz = 0, sz = 0 }
    end

    local npath = 0
    path[npath].b = nil
    npath = npath + 1

    path[0].sz = sz
    path[0].ins = msg
    path[0].lo = npull
    path[0].hi = nmsg

    while b.type == dat.Tpivot do
      if nval(b) > 1 and not b:filledbuf(nmsg, path[npath - 1].sz, self.geom) then
        break
      end
      victim(b, path[npath])
      local sep = getval(b, path[npath].idx)
      b = self:getblk(pack.unpackbp(sep.v), 0)
      npath = npath + 1
      assert(npath < height + 2, "path overran the tree")
    end

    path[npath].b = b
    npath = npath + 1

    local rp = flush(self, t, path, npath)
    local rb = rp.nl

    local dh
    if path[0].nl ~= nil then dh = 1
    elseif path[1].nl ~= nil then dh = 0
    elseif npath > 2 and path[2].nl ~= nil then dh = -1
    else error("broken path change", 0) end

    -- A merged root that still has messages stuck in its buffer is
    -- retried, so the degenerate node does not survive the call.
    local degen = (rb.type == dat.Tpivot and nval(rb) == 1)

    assert(rb.bp.addr ~= 0, "the superblock is not a tree node")

    t.ht = t.ht + dh
    t.bp = rb.bp
    t.dirty = true

    npull = npull + rp.npull
    freepath(self, t, path, npath, true)

    if npull == nmsg and not degen then return end
  end
end

return M
