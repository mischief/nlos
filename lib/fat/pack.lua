-- The on-disk encodings: the BPB, directory entries, long name sets,
-- short name generation, and the packed date and time.
--
-- Everything is little-endian, which is the one place FAT's origin on a
-- small machine shows through. Nothing above this module unpacks a
-- field, so a reader who wants to know what a byte means looks here and
-- nowhere else.

local dat = require "fat.dat"

local M = {}

local spack, sunpack = string.pack, string.unpack
local byte, char, rep, sub = string.byte, string.char, string.rep, string.sub

--------------------------------------------------------------------------
-- a fixed buffer written by offset
--
-- Both the boot sector and a long name entry are mostly holes with
-- fields dropped into them at offsets the specification names. Building
-- them by concatenation would hide those offsets in a running total, so
-- they are written where the specification puts them and the gaps stay
-- zero. Offsets are zero based, as in the BPB tables.

local Buf = {}
Buf.__index = Buf

local function newbuf(n)
  local b = setmetatable({ n = n }, Buf)
  for i = 1, n do b[i] = "\0" end
  return b
end

function Buf:put(off, s)
  assert(off >= 0 and off + #s <= self.n, "field outside the buffer")
  for i = 1, #s do self[off + i] = sub(s, i, i) end
end

function Buf:tostring()
  return table.concat(self, "", 1, self.n)
end

--------------------------------------------------------------------------
-- the BIOS parameter block
--
-- One structure with two tails. The common head stops at byte 36; what
-- follows is either the FAT12/16 tail or the FAT32 one, and which it is
-- cannot be told from the block itself -- only from the cluster count
-- the block describes. So both tails are unpacked and the caller picks.

function M.unpackbpb(s)
  if #s < dat.Secsz then return nil, "short boot sector" end
  local b = {}
  b.oem = sub(s, 4, 11)
  b.bytspersec = sunpack("<I2", s, dat.Obytspersec + 1)
  b.secperclus = byte(s, dat.Osecperclus + 1)
  b.rsvdseccnt = sunpack("<I2", s, dat.Orsvdseccnt + 1)
  b.numfats = byte(s, dat.Onumfats + 1)
  b.rootentcnt = sunpack("<I2", s, dat.Orootentcnt + 1)
  b.totsec16 = sunpack("<I2", s, dat.Ototsec16 + 1)
  b.media = byte(s, 22)
  b.fatsz16 = sunpack("<I2", s, dat.Ofatsz16 + 1)
  b.secpertrk = sunpack("<I2", s, 25)
  b.numheads = sunpack("<I2", s, 27)
  b.hiddsec = sunpack("<I4", s, 29)
  b.totsec32 = sunpack("<I4", s, dat.Ototsec32 + 1)

  -- the FAT32 tail, meaningful only when fatsz16 is zero
  b.fatsz32 = sunpack("<I4", s, dat.Ofatsz32 + 1)
  b.extflags = sunpack("<I2", s, 41)
  b.fsver = sunpack("<I2", s, 43)
  b.rootclus = sunpack("<I4", s, dat.Orootclus + 1)
  b.fsinfo = sunpack("<I2", s, 49)
  b.bkbootsec = sunpack("<I2", s, 51)

  -- the extended boot signature sits at a different offset in each
  -- tail, so the label is read from whichever one claims it
  if byte(s, 39) == dat.Extbootsig then
    b.volid = sunpack("<I4", s, 40)
    b.vollab = sub(s, 44, 54)
    b.filsystype = sub(s, 55, 62)
  elseif byte(s, 67) == dat.Extbootsig then
    b.volid = sunpack("<I4", s, 68)
    b.vollab = sub(s, 72, 82)
    b.filsystype = sub(s, 83, 90)
  end

  b.bootsig = sunpack("<I2", s, 511)
  return b
end

function M.padlabel(s)
  s = (s or "NO NAME"):upper()
  if #s > 11 then s = sub(s, 1, 11) end
  return s .. rep(" ", 11 - #s)
end

-- Build a boot sector. The jump is three bytes of nothing useful: UEFI
-- firmware never executes boot code, and a legacy BIOS that does will
-- jump past the BPB into zeroes and stop, which is the friendlier of
-- the two failures.
function M.packbpb(b)
  local s = newbuf(b.bytspersec or dat.Secsz)
  s:put(0, "\xEB\x58\x90")
  s:put(3, ((b.oem or "LUAFAT  ") .. rep(" ", 8)):sub(1, 8))
  s:put(dat.Obytspersec, spack("<I2", b.bytspersec))
  s:put(dat.Osecperclus, spack("<I1", b.secperclus))
  s:put(dat.Orsvdseccnt, spack("<I2", b.rsvdseccnt))
  s:put(dat.Onumfats, spack("<I1", b.numfats))
  s:put(dat.Orootentcnt, spack("<I2", b.rootentcnt or 0))
  s:put(dat.Ototsec16, spack("<I2", b.totsec16 or 0))
  s:put(21, spack("<I1", b.media or 0xF8))
  s:put(dat.Ofatsz16, spack("<I2", b.fatsz16 or 0))
  s:put(24, spack("<I2", b.secpertrk or 63))
  s:put(26, spack("<I2", b.numheads or 255))
  s:put(28, spack("<I4", b.hiddsec or 0))
  s:put(dat.Ototsec32, spack("<I4", b.totsec32 or 0))

  if b.type == 32 then
    s:put(dat.Ofatsz32, spack("<I4", b.fatsz32))
    s:put(40, spack("<I2", b.extflags or 0))
    s:put(42, spack("<I2", b.fsver or 0))
    s:put(dat.Orootclus, spack("<I4", b.rootclus or dat.Clfirst))
    s:put(48, spack("<I2", b.fsinfo or 1))
    s:put(50, spack("<I2", b.bkbootsec or 6))
    s:put(64, spack("<I1", b.drvnum or 0x80))
    s:put(66, spack("<I1", dat.Extbootsig))
    s:put(67, spack("<I4", b.volid or 0))
    s:put(71, M.padlabel(b.vollab))
    s:put(82, "FAT32   ")
  else
    s:put(36, spack("<I1", b.drvnum or 0x80))
    s:put(38, spack("<I1", dat.Extbootsig))
    s:put(39, spack("<I4", b.volid or 0))
    s:put(43, M.padlabel(b.vollab))
    s:put(54, b.type == 12 and "FAT12   " or "FAT16   ")
  end
  s:put(510, spack("<I2", dat.Bootsig))
  return s:tostring()
end

--------------------------------------------------------------------------
-- FSInfo, which FAT32 keeps and the other two do not
--
-- It is a hint and never a fact. A free count that disagrees with the
-- FAT is the FSInfo being wrong, so open() recomputes rather than
-- trusts, and this is only what carries the hint across a mount.

function M.packfsinfo(free, nextfree, secsz)
  local s = newbuf(secsz or dat.Secsz)
  s:put(0, spack("<I4", dat.Fsileadsig))
  s:put(484, spack("<I4", dat.Fsistrucsig))
  s:put(488, spack("<I4", free or dat.Fsinosuch))
  s:put(492, spack("<I4", nextfree or dat.Fsinosuch))
  s:put(s.n - 4, spack("<I4", dat.Fsitrailsig))
  return s:tostring()
end

function M.unpackfsinfo(s)
  if #s < dat.Secsz then return nil, "short fsinfo" end
  if sunpack("<I4", s, 1) ~= dat.Fsileadsig then
    return nil, "bad fsinfo lead signature"
  end
  if sunpack("<I4", s, 485) ~= dat.Fsistrucsig then
    return nil, "bad fsinfo struct signature"
  end
  return { free = sunpack("<I4", s, 489), next = sunpack("<I4", s, 493) }
end

--------------------------------------------------------------------------
-- dates and times
--
-- FAT counts years from 1980 and seconds in twos. The tenths field on
-- creation buys back one of those seconds and nothing else does, so a
-- write time is even by construction.

-- The calendar is arithmetic here, not os.date and os.time.
--
-- Two reasons. The kernel binds no os library, so a volume served on
-- the target has neither call; and a FAT timestamp has no timezone, so
-- reading one back through localtime makes the same volume give two
-- answers on two machines. These are UTC throughout.
--
-- days between the civil date and 1970-01-01, and back. Valid for any
-- year FAT can hold, which is 1980 to 2107.

local function daysfromcivil(y, m, d)
  y = y - ((m <= 2) and 1 or 0)

  local era = ((y >= 0) and y or (y - 399)) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + ((m > 2) and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy

  return era * 146097 + doe - 719468
end

local function civilfromdays(z)
  z = z + 719468

  local era = ((z >= 0) and z or (z - 146096)) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + ((mp < 10) and 3 or -9)

  return y + ((m <= 2) and 1 or 0), m, d
end

function M.packdate(t)
  local y, m, d = civilfromdays(t // 86400)

  y = y - 1980
  if y < 0 then y = 0 elseif y > 127 then y = 127 end
  return (y << 9) | (m << 5) | d
end

function M.packtime(t)
  local s = t % 86400

  return ((s // 3600) << 11) | ((s % 3600 // 60) << 5) | ((s % 60) // 2)
end

function M.unpackdatetime(date, time)
  if date == 0 then return 0 end

  local days = daysfromcivil(1980 + ((date >> 9) & 0x7F),
      (date >> 5) & 0x0F, date & 0x1F)

  return days * 86400 + ((time >> 11) & 0x1F) * 3600 +
      ((time >> 5) & 0x3F) * 60 + (time & 0x1F) * 2
end

--------------------------------------------------------------------------
-- the short directory entry

function M.unpackdirent(s, pos)
  pos = pos or 1
  local e = {}
  e.name = sub(s, pos, pos + 10)
  e.attr = byte(s, pos + 11)
  e.ntres = byte(s, pos + 12)
  e.crttimetenth = byte(s, pos + 13)
  e.crttime = sunpack("<I2", s, pos + 14)
  e.crtdate = sunpack("<I2", s, pos + 16)
  e.lstaccdate = sunpack("<I2", s, pos + 18)
  e.clushi = sunpack("<I2", s, pos + 20)
  e.wrttime = sunpack("<I2", s, pos + 22)
  e.wrtdate = sunpack("<I2", s, pos + 24)
  e.cluslo = sunpack("<I2", s, pos + 26)
  e.size = sunpack("<I4", s, pos + 28)
  e.clus = (e.clushi << 16) | e.cluslo
  return e
end

function M.packdirent(e)
  local clus = e.clus or 0
  return table.concat({
    e.name,
    spack("<I1", e.attr or 0),
    spack("<I1", e.ntres or 0),
    spack("<I1", e.crttimetenth or 0),
    spack("<I2", e.crttime or 0),
    spack("<I2", e.crtdate or 0),
    spack("<I2", e.lstaccdate or 0),
    spack("<I2", (clus >> 16) & 0xFFFF),
    spack("<I2", e.wrttime or 0),
    spack("<I2", e.wrtdate or 0),
    spack("<I2", clus & 0xFFFF),
    spack("<I4", e.size or 0),
  })
end

--------------------------------------------------------------------------
-- short names
--
-- The eleven bytes on disk are a name padded to eight and an extension
-- padded to three, with no dot between them. One escape: a name whose
-- first byte would be 0xE5 -- a legal Kanji lead byte -- is stored as
-- 0x05, because 0xE5 in that position means the entry is free.

function M.shortname(raw)
  local n = sub(raw, 1, 8):gsub(" +$", "")
  local x = sub(raw, 9, 11):gsub(" +$", "")
  if byte(n, 1) == dat.Ekanji then n = char(dat.Efree) .. sub(n, 2) end
  if x == "" then return n end
  return n .. "." .. x
end

-- Case in a short name
--
-- The eleven bytes are upper case by definition, so a name that is all
-- lower case in one component would need a long entry to say so. Two
-- bits in NTRes say it instead: one for the stem, one for the
-- extension, each meaning "display this part lower case". A component
-- with mixed case has no bit for it and does need the long entry.

M.Lowbase = 0x08
M.Lowext = 0x10

-- The reverse of shortname, for a name that is already 8.3-shaped.
-- Returns nil when it is not, which is how the caller learns a long
-- entry is needed. The second result is the NTRes case bits, or nil
-- when the case cannot be expressed by them.
function M.mkshort(name)
  if name == "." or name == ".." then
    return name .. rep(" ", 11 - #name), 0
  end
  local n, x = name:match("^(.*)%.([^.]*)$")
  if not n or n == "" then n, x = name, "" end
  if #n == 0 or #n > 8 or #x > 3 then return nil end

  local ntres = 0
  local function conv(s, bit)
    local out = {}
    local nlow, nup = 0, 0
    for i = 1, #s do
      local c = sub(s, i, i)
      local u = c:upper()
      if c ~= u then nlow = nlow + 1 elseif c ~= c:lower() then nup = nup + 1 end
      local v = byte(u)
      if v < 0x20 or v > 0x7E or dat.Badshort:find(u, 1, true) then
        return nil
      end
      out[i] = u
    end
    if nlow > 0 and nup > 0 then return nil end     -- mixed, so no bit
    if nlow > 0 then ntres = ntres | bit end
    return table.concat(out)
  end
  n, x = conv(n, M.Lowbase), conv(x, M.Lowext)
  if not n or not x then return nil end
  return n .. rep(" ", 8 - #n) .. x .. rep(" ", 3 - #x), ntres
end

-- A short name as it is shown, with the NTRes case bits applied.
function M.shortcased(raw, ntres)
  ntres = ntres or 0
  local n = sub(raw, 1, 8):gsub(" +$", "")
  local x = sub(raw, 9, 11):gsub(" +$", "")
  if byte(n, 1) == dat.Ekanji then n = char(dat.Efree) .. sub(n, 2) end
  if (ntres & M.Lowbase) ~= 0 then n = n:lower() end
  if (ntres & M.Lowext) ~= 0 then x = x:lower() end
  if x == "" then return n end
  return n .. "." .. x
end

-- The characters a short name may hold, as a Lua pattern class: the
-- alphanumerics and the punctuation FAT allows. Stripping with one
-- gsub rather than a loop matters -- every long name creation strips a
-- stem, and a create is not allowed to be expensive.
local Keep = "[^%w!#%$%%&\'%(%)%-@%^_`{}~]"

-- The legal characters of a name's stem and extension, upper cased and
-- cut to the widths a short name has room for. Worked out once and
-- handed to mangle, which is called repeatedly for the same name.
function M.stems(name)
  local base, ext = name:match("^(.*)%.([^.]*)$")
  if not base or base == "" then base, ext = name, "" end
  base = (base:upper():gsub(Keep, ""))
  ext = (ext:upper():gsub(Keep, ""))
  if base == "" then base = "FILE" end
  return base, sub(ext, 1, 3)
end

local function pad(stem, ext)
  stem = sub(stem, 1, 8)
  return stem .. rep(" ", 8 - #stem) .. ext .. rep(" ", 3 - #ext)
end

-- A short name for a long one: the stem, cut short, then ~n. The caller
-- supplies the tail number, because only it knows which names the
-- directory already holds.
function M.mangle(name, n, base, ext)
  if not base then base, ext = M.stems(name) end
  local tail = "~" .. n
  return pad(sub(base, 1, 8 - #tail) .. tail, ext)
end

-- The same, for a directory that already holds every ~n worth trying.
-- Windows does this too, and for the same reason: a directory of names
-- that differ past the sixth character turns a sequential search into a
-- walk of the whole directory per file, which is quadratic to fill.
--
-- The hash is of the whole name, so two different names almost always
-- get different short names on the first try; seed is bumped by the
-- caller on the rare collision.
function M.hashshort(name, seed, base, ext)
  if not base then base, ext = M.stems(name) end
  local h = seed & 0xFFFF
  for i = 1, #name do
    h = ((h << 5) - h + byte(name, i)) & 0xFFFF
  end
  return pad(("%s%04X~1"):format(sub(base, 1, 2), h), ext)
end

-- The checksum that ties a long name set to the short entry after it.
-- Rotate right, add, keep eight bits. A set whose sum does not match
-- the entry it precedes is stale and is ignored.
function M.chksum(short)
  local sum = 0
  for i = 1, 11 do
    sum = (((sum & 1) << 7) + (sum >> 1) + byte(short, i)) & 0xFF
  end
  return sum
end

--------------------------------------------------------------------------
-- long names
--
-- A long name is UCS-2 split thirteen characters at a time, stored in
-- reverse: the last piece is written first, so a reader walking the
-- directory forward meets the highest ordinal first and learns from its
-- last-flag how many entries belong to the set.
--
-- UEFI 13.3.1.2 says UCS-2, not UTF-16, for sorting and collation.
-- Anything outside the basic plane is therefore not representable, and
-- encoding one is an error rather than a surrogate pair.

function M.utf8toucs2(name)
  local out = {}
  local ok, err = pcall(function()
    for _, cp in utf8.codes(name) do
      if cp > 0xFFFF then error("not UCS-2", 0) end
      out[#out + 1] = spack("<I2", cp)
    end
  end)
  if not ok then return nil, "name is not UCS-2 text: " .. tostring(err) end
  return table.concat(out)
end

function M.ucs2toutf8(s)
  local out = {}
  for i = 1, #s - 1, 2 do
    local cp = sunpack("<I2", s, i)
    if cp == 0 or cp == 0xFFFF then break end
    out[#out + 1] = utf8.char(cp)
  end
  return table.concat(out)
end

-- Where the three name fragments sit in a long entry, zero based, and
-- how many characters each holds. Every path through a long entry needs
-- this, so it is stated once.
local Lfrag = { { 1, 5 }, { 14, 6 }, { 28, 2 } }

M.Lchars = 13   -- 5 + 6 + 2

function M.nlong(name)
  local u = M.utf8toucs2(name)
  if not u then return nil end
  local nch = #u // 2
  return (nch + M.Lchars) // M.Lchars   -- room for the terminator too
end

-- The entries for one name, in the order they go on disk: highest
-- ordinal first, the short entry's own bytes not included.
function M.packlong(name, short)
  local u, err = M.utf8toucs2(name)
  if not u then return nil, err end
  local nch = #u // 2
  local n = (nch + M.Lchars) // M.Lchars
  local sum = M.chksum(short)
  local out = {}
  for i = 1, n do
    local seq = n - i + 1                 -- disk order is descending
    local e = newbuf(dat.Direntsz)
    e:put(0, spack("<I1", seq | (i == 1 and dat.Lastlong or 0)))
    e:put(11, spack("<I1", dat.Along))
    e:put(12, spack("<I1", 0))
    e:put(13, spack("<I1", sum))
    e:put(26, spack("<I2", 0))            -- always zero in a long entry

    local ci = (seq - 1) * M.Lchars       -- characters, zero based
    for _, f in ipairs(Lfrag) do
      local piece = {}
      for k = 1, f[2] do
        local c = ci
        ci = ci + 1
        if c < nch then
          piece[k] = sub(u, c * 2 + 1, c * 2 + 2)
        elseif c == nch then
          piece[k] = "\0\0"               -- the terminator
        else
          piece[k] = "\xFF\xFF"           -- and padding past it
        end
      end
      e:put(f[1], table.concat(piece))
    end
    out[i] = e:tostring()
  end
  return out
end

-- The UCS-2 fragment held by one long entry.
function M.longfrag(s, pos)
  pos = pos or 1
  local out = {}
  for i, f in ipairs(Lfrag) do
    out[i] = sub(s, pos + f[1], pos + f[1] + f[2] * 2 - 1)
  end
  return table.concat(out)
end

function M.longent(s, pos)
  pos = pos or 1
  return {
    ord = byte(s, pos) & 0x3F,
    last = (byte(s, pos) & dat.Lastlong) ~= 0,
    chksum = byte(s, pos + 13),
    frag = M.longfrag(s, pos),
  }
end

return M
