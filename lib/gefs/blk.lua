-- Blocks: what one looks like in memory, and how it turns into bytes.
--
-- Upstream keeps a block as its 16KiB buffer and reaches into it with
-- offsets. Here a block is a Lua table holding its entries as strings,
-- and the byte layout appears only in parse() and pack(). The layout is
-- the same one either way -- an offset table growing up from the start
-- of the region and entries growing down from its end -- because the
-- fill numbers derived from it are written to disk in pivot pointers and
-- have to agree with what 9front computes.
--
-- The accounting is the part to be careful with, not the bytes: valsz,
-- bufsz and the filled* predicates decide when a node splits, and a
-- version of them that is merely close would produce a tree that is
-- valid but shaped differently, which no test would catch and a full
-- disk would.

local dat = require "gefs.dat"
local hash = require "gefs.hash"
local pack = require "gefs.pack"

local M = {}

local spack, sunpack = string.pack, string.unpack
local concat = table.concat
local srep = string.rep

--------------------------------------------------------------------------
-- key order
--
-- memcmp over the shared prefix, then shorter first. Lua compares
-- strings with strcoll, which in the C locale -- the only locale a
-- standalone Lua ever sets -- is byte order, including across the NULs
-- that a packed qid is full of. spec/key_spec.lua asserts that rather
-- than trusting it.

local function keycmp(a, b)
  local na, nb = #a, #b
  if na == nb then
    if a < b then return -1 elseif a > b then return 1 else return 0 end
  end
  local n = na < nb and na or nb
  local x, y = a:sub(1, n), b:sub(1, n)
  if x < y then return -1 elseif x > y then return 1 end
  return na < nb and -1 or 1
end

M.keycmp = keycmp

--------------------------------------------------------------------------
-- entry sizes
--
-- A value costs its own 2-byte offset slot plus a length-prefixed key
-- and value. A message costs the same plus its op byte. msgsz counts the
-- offset slot; the bufsz that goes in the header does not, which is why
-- setmsg adds msgsz-2.

local function valsz(kv)
  return 2 + 2 + #kv.k + 2 + #kv.v
end

local function msgsz(m)
  return 2 + 1 + 2 + #m.k + 2 + #m.v
end

M.valsz = valsz
M.msgsz = msgsz

--------------------------------------------------------------------------
-- construction

local Blk = {}
Blk.__index = Blk

M.Blk = Blk

-- a block with nothing in it. addr and gen come from the allocator; the
-- hash is not known until it is packed.
function M.new(ty, addr, gen)
  local b = setmetatable({
    type = ty,
    bp = { addr = addr or -1, hash = -1, gen = gen or -1 },
    vals = {}, valsz = 0,
    msgs = {}, bufsz = 0,
    logents = {}, logsz = 0,
    logp = dat.zb(),
    logh = -1,
    data = nil,
    dirty = true,
    final = false,
  }, Blk)
  return b
end

-- Contents only: the destination keeps its own address and generation,
-- which is what makes this the copy in copy-on-write rather than an
-- alias. Entries are immutable strings, so sharing them is safe.
function M.copy(n, b)
  n.data = b.data
  n.valsz = b.valsz
  n.bufsz = b.bufsz
  n.logsz = b.logsz
  n.logh = b.logh
  n.logp = { addr = b.logp.addr, hash = b.logp.hash, gen = b.logp.gen }
  n.arena = b.arena
  n.vals, n.msgs, n.logents = {}, {}, {}
  for i = 1, #b.vals do n.vals[i] = b.vals[i] end
  for i = 1, #b.msgs do n.msgs[i] = b.msgs[i] end
  for i = 1, #b.logents do n.logents[i] = b.logents[i] end
  return n
end

--------------------------------------------------------------------------
-- node accessors, tree.c's getval/setval/getmsg/setmsg

function Blk:nval() return #self.vals end
function Blk:nbuf() return #self.msgs end

function Blk:getval(i)
  local kv = self.vals[i]
  assert(kv, "value index out of range")
  return kv
end

function Blk:getmsg(i)
  assert(self.type == dat.Tpivot, "messages live in pivots")
  local m = self.msgs[i]
  assert(m, "message index out of range")
  return m
end

-- values are appended in key order; nothing ever inserts into the middle
-- of a node's value list, because a node is rebuilt rather than edited.
function Blk:setval(kv, geom)
  local spc = (self.type == dat.Tleaf) and geom.leafspc or geom.pivspc
  local n = #self.vals + 1
  self.valsz = self.valsz + 2 + #kv.k + 2 + #kv.v
  assert(2 * n + self.valsz <= spc, "leaf overfull")
  self.vals[n] = kv
end

function Blk:setptr(k, bp, fill, geom)
  self:setval({ k = k, v = pack.packptr(bp, fill) }, geom)
end

function Blk:setmsg(m, geom)
  assert(self.type == dat.Tpivot, "messages live in pivots")
  local n = #self.msgs + 1
  self.bufsz = self.bufsz + msgsz(m) - 2
  assert(2 * n + self.bufsz <= geom.bufspc, "buffer overfull")
  self.msgs[n] = m
end

-- fastupsert's one exception: a message goes into the middle of an
-- already-sorted buffer, keeping the run of equal keys in arrival order.
function Blk:insmsg(at, m, geom)
  assert(self.type == dat.Tpivot, "messages live in pivots")
  self.bufsz = self.bufsz + msgsz(m) - 2
  assert(2 * (#self.msgs + 1) + self.bufsz <= geom.bufspc, "buffer overfull")
  table.insert(self.msgs, at, m)
end

function M.getptr(kv)
  return pack.unpackptr(kv.v)
end

--------------------------------------------------------------------------
-- fill and the split thresholds

function Blk:fill()
  if self.type == dat.Tpivot then
    return 2 * #self.msgs + self.bufsz + 2 * #self.vals + self.valsz
  elseif self.type == dat.Tleaf then
    return 2 * #self.vals + self.valsz
  end
  error("block " .. tostring(self.bp.addr) .. " has no fill")
end

function Blk:buffill()
  assert(self.type == dat.Tpivot)
  return 2 * #self.msgs + self.bufsz
end

function Blk:filledbuf(nmsg, needed, geom)
  assert(self.type == dat.Tpivot)
  return 2 * (#self.msgs + nmsg) + self.bufsz + needed > geom.bufspc
end

function Blk:filledleaf(needed, geom)
  assert(self.type == dat.Tleaf)
  return 2 * (#self.vals + 1) + self.valsz + needed > geom.leafspc
end

-- A pivot must always have room for one more message, so that a split
-- propagating up the path has somewhere to land at every level. Each
-- key-pointer pair costs 8 bytes of overhead on top of the key and the
-- pointer: two for the fill, two for the offset slot, and two each for
-- the key and value lengths.
function Blk:filledpiv(reserve, geom)
  assert(self.type == dat.Tpivot)
  return 2 * (#self.vals + 1) + self.valsz
    + reserve * (8 + dat.Keymax + dat.Ptrsz) > geom.pivspc
end

--------------------------------------------------------------------------
-- bytes in

local function parseents(s, base, spc, n, withop)
  local out = {}
  local sz = 0
  for i = 1, n do
    local off = sunpack(">I2", s, base + 2 * (i - 1))
    local p = base + off
    local op
    if withop then
      op = sunpack(">I1", s, p); p = p + 1
    end
    local k, v
    k, p = sunpack(">s2", s, p)
    v, p = sunpack(">s2", s, p)
    out[i] = withop and { op = op, k = k, v = v } or { k = k, v = v }
    sz = sz + (withop and (msgsz(out[i]) - 2) or (2 + #k + 2 + #v))
    if p - base > spc then
      error("entry runs past the end of its region")
    end
  end
  return out, sz
end

-- flags, matching upstream's GB* set
M.GBraw = 1 << 0        -- read it as a data block whatever its header says
M.GBnochk = 1 << 2      -- do not verify the hash

function M.parse(s, bp, geom, flg)
  flg = flg or 0
  assert(#s == geom.blksz, "short block")

  local b = M.new(dat.Tdat, bp.addr, -1)
  b.dirty = false
  b.bp.hash = -1
  b.bp.gen = -1

  local ty = (flg & M.GBraw) ~= 0 and dat.Tdat or sunpack(">I2", s, 1)
  b.type = ty

  local xh, ck
  if ty == dat.Tdat or ty == dat.Tsuper then
    b.data = s
  elseif ty == dat.Tarena then
    b.data = s
    b.arena = pack.unpackarena(s:sub(3, 2 + dat.Arenasz))
  elseif ty == dat.Tlog or ty == dat.Tdlist then
    b.logsz = sunpack(">I2", s, 3)
    b.logh = sunpack(">i8", s, 5)
    b.logp = pack.unpackbp(s, 13)
    if b.logsz < 0 or b.logsz > geom.logspc or b.logsz % 8 ~= 0 then
      return nil, "malformed log block"
    end
    b.data = s:sub(dat.Loghdsz + 1, dat.Loghdsz + b.logsz)
    for i = 1, b.logsz // 8 do
      b.logents[i] = b.data:sub(8 * i - 7, 8 * i)
    end
  elseif ty == dat.Tpivot then
    local nval = sunpack(">I2", s, 3)
    local vsz = sunpack(">I2", s, 5)
    local nbuf = sunpack(">I2", s, 7)
    local bsz = sunpack(">I2", s, 9)
    local base = dat.Pivhdsz + 1
    local ok, vals, gotv = pcall(parseents, s, base, geom.pivspc, nval, false)
    if not ok then return nil, vals end
    local msgs, gotb
    ok, msgs, gotb = pcall(parseents, s, base + geom.pivspc, geom.bufspc,
      nbuf, true)
    if not ok then return nil, msgs end
    if gotv ~= vsz or gotb ~= bsz then
      return nil, "pivot header disagrees with its contents"
    end
    b.vals, b.valsz = vals, gotv
    b.msgs, b.bufsz = msgs, gotb
  elseif ty == dat.Tleaf then
    local nval = sunpack(">I2", s, 3)
    local vsz = sunpack(">I2", s, 5)
    local ok, vals, gotv = pcall(parseents, s, dat.Leafhdsz + 1,
      geom.leafspc, nval, false)
    if not ok then return nil, vals end
    if gotv ~= vsz then
      return nil, "leaf header disagrees with its contents"
    end
    b.vals, b.valsz = vals, gotv
  else
    return nil, "invalid block type " .. ty
  end

  -- log blocks are overwritten in place, so their pointer cannot carry
  -- the hash: they hash their own body into their own header instead.
  if ty == dat.Tlog or ty == dat.Tdlist then
    xh = b.logh
    ck = b.logsz > 0 and hash.bufhash(b.data, 1, b.logsz)
      or hash.bufhash("", 1, 0)
  else
    xh = bp.hash
    ck = hash.blkhash(s)
  end
  if (flg & M.GBnochk) == 0 and ck ~= xh then
    return nil, string.format("corrupt block at %d: %x != %x",
      bp.addr, xh, ck)
  end
  return b
end

--------------------------------------------------------------------------
-- bytes out
--
-- The offset table runs up from the start of the region and the entries
-- run down from its end, so the entries appear in the packed bytes in
-- reverse of the order they were added.

local function packents(ents, spc, withop)
  local offs, blobs = {}, {}
  local sz = 0
  local n = #ents
  for i = 1, n do
    local e = ents[i]
    local blob
    if withop then
      blob = spack(">I1", e.op) .. spack(">s2", e.k) .. spack(">s2", e.v)
    else
      blob = spack(">s2", e.k) .. spack(">s2", e.v)
    end
    sz = sz + #blob
    offs[i] = spack(">I2", spc - sz)
    blobs[n - i + 1] = blob
  end
  local head = concat(offs)
  local tail = concat(blobs)
  local gap = spc - #head - #tail
  assert(gap >= 0, "region overfull")
  return concat({ head, srep("\0", gap), tail }), sz
end

function M.pack(b, geom)
  local blksz = geom.blksz
  local out

  if b.type == dat.Tdat or b.type == dat.Tsuper then
    out = b.data
  elseif b.type == dat.Tarena then
    out = spack(">I2", b.type) .. pack.packarena(b.arena)
    out = out .. srep("\0", blksz - #out)
  elseif b.type == dat.Tlog or b.type == dat.Tdlist then
    local body = concat(b.logents)
    assert(#body == b.logsz, "log size disagrees with its entries")
    b.logh = hash.bufhash(body, 1, #body)
    b.data = body
    local hdr = concat({
      spack(">I2", b.type), spack(">I2", b.logsz), spack(">i8", b.logh),
      pack.packbp(b.logp),
    })
    assert(#hdr == dat.Loghdsz)
    out = hdr .. body .. srep("\0", geom.logspc - #body)
  elseif b.type == dat.Tpivot then
    local vals, vsz = packents(b.vals, geom.pivspc, false)
    local msgs, bsz = packents(b.msgs, geom.bufspc, true)
    assert(vsz == b.valsz and bsz == b.bufsz, "pivot accounting drifted")
    out = concat({
      spack(">I2I2I2I2I2", b.type, #b.vals, vsz, #b.msgs, bsz),
      vals, msgs,
    })
  elseif b.type == dat.Tleaf then
    local vals, vsz = packents(b.vals, geom.leafspc, false)
    assert(vsz == b.valsz, "leaf accounting drifted")
    out = concat({
      spack(">I2I2I2", b.type, #b.vals, vsz), vals,
    })
  else
    error("cannot pack block type " .. tostring(b.type))
  end

  assert(#out == blksz, "packed block is the wrong size: " .. #out)
  b.bp.hash = hash.blkhash(out)
  b.final = true
  return out
end

return M
