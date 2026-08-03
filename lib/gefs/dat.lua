-- On-disk constants, shared by every layer.
--
-- These are gefs's dat.h. The names are kept because the algorithms
-- below read as ports of tree.c, blk.c and fs.c, and a reader with the
-- 9front source open should be able to put them side by side.
--
-- Anything that depends on the block size is computed by geom() from
-- the superblock rather than fixed here: a volume records its own blksz
-- and bufsz, so a reader honours what it finds instead of what it was
-- compiled with.

local M = {}

M.KiB = 1024
M.MiB = 1024 * M.KiB
M.GiB = 1024 * M.MiB
M.TiB = 1024 * M.GiB

M.Lgblk = 14
M.Blksz = 1 << M.Lgblk

M.Maxent = 256                  -- biggest ent key, terminator included
M.Maxname = M.Maxent - 1 - 9 - 1
M.Maxuname = 64

M.Keymax = M.Maxent             -- key data limit
M.Inlmax = 512                  -- inline value limit
M.Ptrsz = 24                    -- off, hash, gen
M.Pptrsz = 26                   -- off, hash, gen, fill
M.Fillsz = 2
M.Offksz = 17                   -- type, qid, off
M.Snapsz = 9                    -- tag, snapid
M.Dpfxsz = 9                    -- directory prefix
M.Upksz = 9
M.Dlksz = 1 + 8 + 8             -- tag, death, birth
M.Dlvsz = M.Ptrsz + M.Ptrsz     -- hd, tl of deadlist
M.Dlkvpsz = M.Dlksz + M.Dlvsz
M.Treesz = 4 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + M.Ptrsz
M.Xdirsz = 8 + 8 + 4 + 1 + 4 + 8 + 8 + 8 + 4 + 4 + 4
M.Kvmax = M.Keymax + M.Inlmax
M.Kpmax = M.Keymax + M.Ptrsz
M.Wstatmax = 4 + 8 + 8 + 8
M.Arenasz = 8 + 8 + 8 + 8

M.Pivhdsz = 10                  -- type, nval, valsz, nbuf, bufsz
M.Leafhdsz = 6                  -- type, nval, valsz
M.Loghdsz = 2 + 2 + 8 + M.Ptrsz -- type, len, hash, chain
M.Rootsz = 4 + M.Ptrsz
M.Logslop = 16 + 16 + 8         -- val, nextb, chain
M.Msgmax = 1 + (M.Kvmax > M.Kpmax and M.Kvmax or M.Kpmax)

M.Nsec = 1000000000

-- block types. Tdat is also what an unformatted or refcount block reads
-- as, so it is the one type with no header of its own.
M.Tdat = 0
M.Tpivot = 1
M.Tleaf = 2
M.Tlog = 3
M.Tdlist = 4
M.Tarena = 5
M.Tsuper = 0x6765               -- 'ge', big-endian, so a superblock is
                                -- self-identifying from its first two bytes

M.typename = {
  [M.Tdat] = "dat", [M.Tpivot] = "pivot", [M.Tleaf] = "leaf",
  [M.Tlog] = "log", [M.Tdlist] = "dlist", [M.Tarena] = "arena",
  [M.Tsuper] = "super",
}

-- key namespaces. The first byte of every key is one of these, so the
-- tree's global ordering groups all data blocks, then all dirents, and
-- so on. Nothing outside this list may appear in a key.
M.Kdat = 0      -- qid[8] off[8] => bptr:      pointer to a data block
M.Kent = 1      -- pqid[8] name[n] => dir[n]:  serialized Xdir
M.Kup = 2       -- qid[8] => Kent:             parent dir
M.Klabel = 3    -- name[] => snapid[]:         snapshot label
M.Ksnap = 4     -- sid[8] => ref[8], tree[]:   snapshot root
M.Kdlist = 5    -- snap[8] gen[8] => hd, tl:   deadlist
M.Kconf = 6     -- name[] => value[]

M.keyname = {
  [M.Kdat] = "dat", [M.Kent] = "ent", [M.Kup] = "up",
  [M.Klabel] = "label", [M.Ksnap] = "snap", [M.Kdlist] = "dlist",
  [M.Kconf] = "conf",
}

-- message ops, in the order the tree applies them
M.Onop = 0
M.Oinsert = 1
M.Odelete = 2
M.Oclearb = 3   -- free the block pointer if one exists
M.Oclobber = 4  -- remove the file if it exists
M.Owstat = 5    -- update a dirent in place
M.Orelink = 6   -- rechain forwards
M.Oreprev = 7   -- rechain backwards
M.Oincref = 8   -- adjust refs on a snap
M.Nmsgtype = 9

M.opname = {
  [M.Onop] = "nop", [M.Oinsert] = "insert", [M.Odelete] = "delete",
  [M.Oclearb] = "clearb", [M.Oclobber] = "clobber", [M.Owstat] = "wstat",
  [M.Orelink] = "relink", [M.Oreprev] = "reprev", [M.Oincref] = "incref",
}

-- wstat carries its fields in bit order, so a reader walks the flag byte
-- and consumes exactly the fields it names
M.Owsize = 1 << 0
M.Owmode = 1 << 1
M.Owmtime = 1 << 2
M.Owatime = 1 << 3
M.Owuid = 1 << 4
M.Owgid = 1 << 5
M.Owmuid = 1 << 6
M.Owqpath = 1 << 7

-- allocation log ops, or'ed into the low byte of the offset. Entries at
-- or above Log2wide carry a second 8-byte word.
M.LogNop = 0
M.LogAlloc1 = 1
M.LogFree1 = 2
M.LogSync = 3
M.Log2wide = 4
M.LogAlloc = 4
M.LogFree = 5

-- snapshot label flags
M.Lmut = 1 << 0                 -- snaps may be taken through this label

-- 9P mode and qid bits, needed because dirents store them verbatim
M.QTFILE = 0x00
M.QTTMP = 0x04
M.QTAUTH = 0x08
M.QTMOUNT = 0x10
M.QTEXCL = 0x20
M.QTAPPEND = 0x40
M.QTDIR = 0x80

M.DMDIR = 0x80000000
M.DMAPPEND = 0x40000000
M.DMEXCL = 0x20000000
M.DMMOUNT = 0x10000000
M.DMAUTH = 0x08000000
M.DMTMP = 0x04000000
M.DMREAD = 4
M.DMWRITE = 2
M.DMEXEC = 1

-- the qids ream() hands out, before any file exists
M.Qmainroot = 0
M.Qadmroot = 1
M.Qadmuser = 2
M.Nreamqid = 3

-- Qids with the top bit set are served by the filesystem itself rather
-- than by the tree. Setting the top bit is also what caps how many files
-- a volume can ever hold, which is why fscreate refuses past Qdump.
M.Qmagic = 1 << 63
M.Qdump = M.Qmagic
M.Qctl = M.Qmagic + 1
M.Qstatus = M.Qmagic + 2

-- an unset block pointer. Held by value everywhere; never shared.
function M.zb()
  return { addr = -1, hash = -1, gen = -1 }
end

-- Everything sized against the block. A volume carries blksz and bufsz
-- in its superblock, so these come from what was read rather than from
-- what this build would have chosen.
--
-- Smaller blocks work but change the tree's behaviour, and one threshold
-- is worth knowing before choosing one. Two nodes merge only if they fit
-- together with four maximum messages of slack, and a maximum message is
-- Msgmax bytes whatever the block size; below roughly 12KiB that leaves
-- pivspc with nothing, so nodes never merge and a tree that empties out
-- keeps its shape. Blocks are still reclaimed either way. 16KiB is the
-- size gefs uses and the size a volume from 9front will have.
function M.geom(blksz, bufspc)
  blksz = blksz or M.Blksz
  bufspc = bufspc or ((blksz - M.Pivhdsz) // 2)
  return {
    blksz = blksz,
    bufspc = bufspc,
    pivspc = blksz - M.Pivhdsz - bufspc,
    leafspc = blksz - M.Leafhdsz,
    logspc = blksz - M.Loghdsz,
  }
end

return M
