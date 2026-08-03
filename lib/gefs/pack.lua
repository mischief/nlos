-- The on-disk encodings, gefs's pack.c.
--
-- Everything is big-endian, which is also why a superblock starts
-- "gefs9.00": the first two bytes read back as the block type 0x6765,
-- so a superblock announces itself twice over.
--
-- Keys and values are plain byte strings here. The tree never looks
-- inside them except to compare, so this module is the only place that
-- knows what a dirent or a snapshot record is made of.

local dat = require "gefs.dat"

local M = {}

local spack, sunpack = string.pack, string.unpack

--------------------------------------------------------------------------
-- strings, as they appear inside keys
--
-- The terminating NUL is part of the encoding, not an accident of C: it
-- is what lets 9front use a key's name in place without copying it.

function M.packstr(s)
  assert(#s < 0x10000, "string too long")
  return spack(">s2", s) .. "\0"
end

-- returns the string and the offset one past its terminator
function M.unpackstr(s, pos)
  if #s - pos + 1 < 3 then return nil, "short string" end
  local n = sunpack(">I2", s, pos)
  if #s - pos + 1 < n + 3 then return nil, "short string" end
  if s:byte(pos + 2 + n) ~= 0 then return nil, "unterminated string" end
  return s:sub(pos + 2, pos + 1 + n), pos + n + 3
end

--------------------------------------------------------------------------
-- block pointers

function M.packbp(bp)
  return spack(">i8i8i8", bp.addr, bp.hash, bp.gen)
end

function M.unpackbp(s, pos)
  pos = pos or 1
  assert(#s - pos + 1 >= dat.Ptrsz, "short block pointer")
  local addr, hash, gen = sunpack(">i8i8i8", s, pos)
  return { addr = addr, hash = hash, gen = gen }
end

-- a pivot's value is a pointer plus the fill of what it points at, so a
-- parent can decide to merge without reading the child
function M.packptr(bp, fill)
  return M.packbp(bp) .. spack(">I2", fill)
end

function M.unpackptr(s)
  assert(#s == dat.Pptrsz, "not a pivot pointer")
  return M.unpackbp(s, 1), sunpack(">I2", s, dat.Ptrsz + 1)
end

--------------------------------------------------------------------------
-- directory entries: Kent{pqid, name} => Xdir

function M.packdkey(up, name)
  local k = spack(">I1i8", dat.Kent, up)
  if name ~= nil then k = k .. M.packstr(name) end
  return k
end

-- the (parent qid, name) a Kup value points at
function M.unpackdkey(k)
  assert(#k > 9, "short dirent key")
  assert(k:byte(1) == dat.Kent, "not a dirent key")
  local up = sunpack(">i8", k, 2)
  local name = M.unpackstr(k, 10)
  return up, name
end

-- Kup{qid} => Kent{parent}, the back pointer that makes a walk to ".."
-- a lookup rather than a search
function M.packsuper(up)
  return spack(">I1i8", dat.Kup, up)
end

function M.packdval(d)
  return spack(">i8i8I4I1I4i8i8i8i4i4i4",
    d.flag or 0, d.qid.path, d.qid.vers, d.qid.type,
    d.mode, d.atime, d.mtime, d.length,
    d.uid, d.gid, d.muid)
end

function M.unpackdval(v)
  assert(#v == dat.Xdirsz, "malformed dirent value")
  local flag, path, vers, qtype, mode, atime, mtime, length, uid, gid, muid =
    sunpack(">i8i8I4I1I4i8i8i8i4i4i4", v)
  return {
    flag = flag,
    qid = { path = path, vers = vers, type = qtype },
    mode = mode, atime = atime, mtime = mtime, length = length,
    uid = uid, gid = gid, muid = muid,
  }
end

function M.dir2kv(up, d)
  return M.packdkey(up, d.name), M.packdval(d)
end

function M.kv2dir(k, v)
  local d = M.unpackdval(v)
  assert(#k >= 9, "short dirent key")
  d.name = M.unpackstr(k, 10)
  return d
end

--------------------------------------------------------------------------
-- snapshots: Klabel{name} => Ksnap{id}, and Ksnap{id} => Tree

function M.packlbl(name)
  return spack(">I1", dat.Klabel) .. name
end

function M.packsnap(id)
  return spack(">I1i8", dat.Ksnap, id)
end

function M.lbl2kv(lbl, gen, flg)
  return M.packlbl(lbl), spack(">I1i8I4", dat.Ksnap, gen, flg)
end

function M.kv2lbl(v)
  assert(#v == 1 + 8 + 4, "malformed label value")
  local tag, gen, flg = sunpack(">I1i8I4", v)
  assert(tag == dat.Ksnap, "label does not name a snapshot")
  return gen, flg
end

function M.packtree(t)
  return spack(">i4i4i4I4i8i8i8i8i8i8i8",
    t.nref, t.nlbl, t.ht, t.flag,
    t.gen, t.pred, t.succ, t.base,
    t.bp.addr, t.bp.hash, t.bp.gen)
end

function M.unpacktree(v)
  assert(#v >= dat.Treesz, "short tree record")
  local nref, nlbl, ht, flag, gen, pred, succ, base, addr, hash, bgen =
    sunpack(">i4i4i4I4i8i8i8i8i8i8i8", v)
  return {
    nref = nref, nlbl = nlbl, ht = ht, flag = flag,
    gen = gen, pred = pred, succ = succ, base = base,
    bp = { addr = addr, hash = hash, gen = bgen },
  }
end

function M.tree2kv(t)
  return M.packsnap(t.gen), M.packtree(t)
end

-- the payload of Orelink, Oreprev and Oincref: a link to rewrite and a
-- pair of signed adjustments to the label and fork counts
function M.retag2kv(gen, link, dlbl, dref)
  assert(gen ~= -1)
  return M.packsnap(gen), spack(">i8i1i1", link, dlbl, dref)
end

function M.unpackretag(v)
  assert(#v == 8 + 1 + 1, "malformed retag")
  return sunpack(">i8i1i1", v)
end

--------------------------------------------------------------------------
-- deadlists: Kdlist{snap, gen} => head, tail

function M.dlist2kv(dl)
  return spack(">I1i8i8", dat.Kdlist, dl.gen, dl.bgen),
    M.packbp(dl.hd) .. M.packbp(dl.tl)
end

function M.kv2dlist(k, v)
  local gen, bgen = sunpack(">i8i8", k, 2)
  return {
    gen = gen, bgen = bgen,
    hd = M.unpackbp(v, 1),
    tl = M.unpackbp(v, dat.Ptrsz + 1),
  }
end

--------------------------------------------------------------------------
-- data keys: Kdat{qid, offset} => bptr

function M.packdatkey(qpath, off)
  return spack(">I1i8i8", dat.Kdat, qpath, off)
end

function M.unpackdatkey(k)
  assert(#k == dat.Offksz, "malformed data key")
  return sunpack(">i8i8", k, 2)
end

--------------------------------------------------------------------------
-- arena headers, overwritten in place rather than shadowed

function M.packarena(a)
  return spack(">i8i8i8i8", a.loghd.addr, a.loghd.hash, a.size, a.used)
end

function M.unpackarena(s)
  local addr, hash, size, used = sunpack(">i8i8i8i8", s)
  return {
    loghd = { addr = addr, hash = hash, gen = -1 },
    size = size, used = used,
  }
end

--------------------------------------------------------------------------
-- the superblock
--
-- It carries its own checksum over its own prefix rather than relying on
-- a block pointer, because nothing points at it: it is the thing found
-- by looking at a fixed address.

local SBVERS = "gefs9.00"

M.SBVERS = SBVERS

function M.packsb(fi, blksz)
  local t = {
    SBVERS,
    spack(">I4I4I4I4", blksz, fi.bufspc, fi.narena, fi.snap.ht),
    spack(">i8i8", fi.snap.bp.addr, fi.snap.bp.hash),
    spack(">i8i8", fi.snapdl.hd.addr, fi.snapdl.hd.hash),
    spack(">i8i8", fi.snapdl.tl.addr, fi.snapdl.tl.hash),
    spack(">i8i8i8i8", fi.flag, fi.nextqid, fi.nextgen, fi.qgen),
  }
  for i = 1, fi.narena do
    t[#t + 1] = spack(">i8i8", fi.arenabp[i].addr, fi.arenabp[i].hash)
  end
  local body = table.concat(t)
  local hash = require("gefs.hash").bufhash(body, 1, #body)
  return body .. spack(">i8", hash)
end

function M.unpacksb(s)
  if s:sub(1, 8) ~= SBVERS then
    return nil, "unknown filesystem version " .. s:sub(1, 8):gsub("%c", "?")
  end
  local fi = { snap = {}, snapdl = {}, arenabp = {} }
  local p = 9
  local blksz, bufspc, narena, ht = sunpack(">I4I4I4I4", s, p); p = p + 16
  local raddr, rhash = sunpack(">i8i8", s, p); p = p + 16
  local dhaddr, dhhash = sunpack(">i8i8", s, p); p = p + 16
  local dtaddr, dthash = sunpack(">i8i8", s, p); p = p + 16
  local flag, nextqid, nextgen, qgen = sunpack(">i8i8i8i8", s, p); p = p + 32

  fi.blksz = blksz
  fi.bufspc = bufspc
  fi.narena = narena
  fi.snap.ht = ht
  fi.snap.bp = { addr = raddr, hash = rhash, gen = -1 }
  fi.snapdl.gen = -1
  fi.snapdl.hd = { addr = dhaddr, hash = dhhash, gen = -1 }
  fi.snapdl.tl = { addr = dtaddr, hash = dthash, gen = -1 }
  fi.flag = flag
  fi.nextqid = nextqid
  fi.nextgen = nextgen
  fi.qgen = qgen

  if narena < 0 or narena >= 512 then
    return nil, "implausible arena count " .. narena
  end
  for i = 1, narena do
    local addr, hash = sunpack(">i8i8", s, p); p = p + 16
    fi.arenabp[i] = { addr = addr, hash = hash, gen = -1 }
  end

  local want = require("gefs.hash").bufhash(s, 1, p - 1)
  local got = sunpack(">i8", s, p)
  if want ~= got then
    return nil, string.format("corrupt superblock: %x != %x", got, want)
  end
  return fi
end

--------------------------------------------------------------------------
-- an Xdir with nothing in it yet, for the entries ream() plants

function M.fillxdir(qid, name, qtype, mode, len)
  return {
    flag = 0,
    qid = { path = qid, vers = 0, type = qtype },
    mode = mode,
    atime = 0, mtime = 0,
    length = len,
    name = name,
    uid = -1, gid = -1, muid = 0,
  }
end

return M
