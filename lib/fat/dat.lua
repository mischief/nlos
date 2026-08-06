-- The on-disk constants of FAT, as UEFI 13.3.1 fixes them.
--
-- The names are the ones the BPB uses, so a field here and a field in
-- the specification are looked up under the same word. Everything on
-- disk is little-endian; this is the only fact about byte order in the
-- whole tree, and pack.lua is the only module that acts on it.

local M = {}

--------------------------------------------------------------------------
-- geometry

M.Secsz = 512           -- the usual sector, and the only one ream makes
M.Direntsz = 32         -- every directory entry, long or short
M.Maxname = 255         -- characters in a long name
M.Maxpath = 4096
M.Maxfile = 0xFFFFFFFF  -- FileSize is 32 bits, so a file stops here

-- The three variants, told apart by the count of data clusters and by
-- nothing else. These two numbers are the whole of the rule: below the
-- first is FAT12, below the second FAT16, at or above it FAT32.
M.Fat12max = 4085
M.Fat16max = 65525

--------------------------------------------------------------------------
-- cluster numbers
--
-- 0 and 1 are not clusters. The first real one is 2, which is why the
-- data region starts one cluster pair early in every address sum.

M.Clfree = 0
M.Clfirst = 2
M.Clbad = { [12] = 0xFF7, [16] = 0xFFF7, [32] = 0x0FFFFFF7 }
M.Cleof = { [12] = 0xFFF, [16] = 0xFFFF, [32] = 0x0FFFFFFF }
M.Clmask = { [12] = 0xFFF, [16] = 0xFFFF, [32] = 0x0FFFFFFF }

-- The end of a chain is any value at or above this, not one value: a
-- writer is allowed to plant any of them and a reader must accept all.
M.Cleofmin = { [12] = 0xFF8, [16] = 0xFFF8, [32] = 0x0FFFFFF8 }

--------------------------------------------------------------------------
-- directory entries

M.Aread = 0x01
M.Ahidden = 0x02
M.Asystem = 0x04
M.Avolume = 0x08
M.Adir = 0x10
M.Aarchive = 0x20
M.Along = 0x0F          -- read-only|hidden|system|volume, which no real
                        -- entry carries, so an old reader skips it

M.Efree = 0xE5          -- this entry is free
M.Eend = 0x00           -- this entry is free and so is every one after
M.Ekanji = 0x05         -- a leading 0xE5 in a name, escaped

M.Lastlong = 0x40       -- in a long entry's ordinal: the last of the set

--------------------------------------------------------------------------
-- signatures

M.Bootsig = 0xAA55
M.Extbootsig = 0x29
M.Fsileadsig = 0x41615252
M.Fsistrucsig = 0x61417272
M.Fsitrailsig = 0xAA550000
M.Fsinosuch = 0xFFFFFFFF  -- FSInfo's "I do not know"

--------------------------------------------------------------------------
-- BPB field offsets, zero based, for the places that address bytes
-- rather than unpack the whole block

M.Obytspersec = 11
M.Osecperclus = 13
M.Orsvdseccnt = 14
M.Onumfats = 16
M.Orootentcnt = 17
M.Ototsec16 = 19
M.Ofatsz16 = 22
M.Ototsec32 = 32
M.Ofatsz32 = 36
M.Orootclus = 44

-- The characters a short name may not hold. Long names are wider, and
-- okname in pack.lua is where that difference lives.
M.Badshort = "\"*+,./:;<=>?[\\]|"

return M
