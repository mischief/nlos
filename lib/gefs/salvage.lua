-- Pulling files out of an image that no longer opens.
--
-- Nothing here reads the superblock, follows a tree, or trusts a
-- pointer it was handed. It sweeps the raw device block by block and
-- picks up whatever is still legible, which works because of three
-- properties of the format:
--
--   * every metadata block names its own type in its first two bytes,
--     and a leaf or a pivot parses on its own with no context;
--   * a dirent is self-contained -- Kent{parent qid, name} holding a
--     whole Xdir -- so the namespace can be rebuilt from the entries
--     alone, without a single tree walk;
--   * a Kdat value is a block pointer carrying both a generation and a
--     hash. The generation says which of several surviving copies of a
--     block is the newest, and the hash says whether the bytes at the
--     other end are the ones that were written there.
--
-- That last one is why this can do better than guessing. Copy-on-write
-- leaves older versions of blocks lying around until they are reclaimed,
-- so a sweep finds several candidates for the same key; the generation
-- picks between them, and the recovered data is verified rather than
-- hoped over.

local dat = require "gefs.dat"
local blk = require "gefs.blk"
local hash = require "gefs.hash"
local pack = require "gefs.pack"

local M = {}

local sunpack = string.unpack

--------------------------------------------------------------------------
-- finding the block size
--
-- It is in the superblock, and the superblock is the thing that may be
-- gone. Failing that, try each plausible size and see which one makes
-- the most blocks parse: a wrong size lands the header in the middle of
-- somebody else's data and almost nothing comes out.

local CANDIDATES = { 16384, 32768, 8192, 4096, 65536 }

function M.blocksize(dev, opts)
  opts = opts or {}
  if opts.blksz then return opts.blksz, "given" end

  local size = dev:size()
  for _, addr in ipairs({ 0, size - size % dat.Blksz - dat.Blksz }) do
    if addr >= 0 and addr + 64 <= size then
      local ok, s = pcall(dev.read, dev, addr, math.min(dat.Blksz, size - addr))
      if ok and s ~= nil then
        local fi = pack.unpacksb(s)
        if fi ~= nil then return fi.blksz, "superblock" end
      end
    end
  end

  -- Sample windows spread across the whole device, and inside each
  -- window try every candidate size on the same bytes. Two things make
  -- that the right shape. A volume's metadata sits wherever its arenas
  -- are, so looking only at the front of a big device finds nothing; and
  -- scoring the candidates against different samples would compare
  -- numbers that are not comparable, since a bigger size sees fewer
  -- block starts in the same span.
  local WINDOW = CANDIDATES[1]
  for _, bs in ipairs(CANDIDATES) do
    if bs > WINDOW then WINDOW = bs end
  end
  local WINDOWS = 3000

  local nwin = size // WINDOW
  if nwin == 0 then return dat.Blksz, "assumed" end
  local stride = nwin // WINDOWS
  if stride < 1 then stride = 1 end

  local score = {}
  for _, bs in ipairs(CANDIDATES) do score[bs] = 0 end

  local w = 0
  while w < nwin do
    local base = w * WINDOW
    local ok, win = pcall(dev.read, dev, base, WINDOW)
    if ok and win ~= nil and #win == WINDOW then
      for _, bs in ipairs(CANDIDATES) do
        local geom = dat.geom(bs)
        for off = 0, WINDOW - bs, bs do
          local s = win:sub(off + 1, off + bs)
          local ty = sunpack(">I2", s)
          if ty == dat.Tleaf or ty == dat.Tpivot then
            if blk.parse(s, { addr = base + off, hash = -1, gen = -1 },
              geom, blk.GBnochk) ~= nil then
              score[bs] = score[bs] + 1
            end
          end
        end
      end
    end
    w = w + stride
  end

  -- Strictly better wins, so a tie goes to the earlier and smaller
  -- candidate. That is the right way round: reading a 16KiB block as the
  -- first half of a 32KiB one can parse by accident, and a real volume
  -- of the smaller size has more block starts to find.
  local best, bestn = nil, 0
  for _, bs in ipairs(CANDIDATES) do
    if score[bs] > bestn then best, bestn = bs, score[bs] end
  end
  if best == nil then return dat.Blksz, "assumed" end
  return best, "guessed"
end

--------------------------------------------------------------------------
-- the sweep

local function better_ent(new, old)
  if old == nil then return true end
  if new.qid.vers ~= old.qid.vers then return new.qid.vers > old.qid.vers end
  if new.mtime ~= old.mtime then return new.mtime > old.mtime end
  -- a longer file is the safer guess when nothing else separates them
  return new.length > old.length
end

local function harvest(cat, k, v, op)
  if #k == 0 then return end
  local kind = k:byte(1)

  if kind == dat.Kent then
    if op == dat.Odelete or op == dat.Oclobber then return end
    if #v ~= dat.Xdirsz or #k < 12 then return end
    local ok, d = pcall(pack.kv2dir, k, v)
    if not ok then return end
    d.up = sunpack(">i8", k, 2)
    local q = d.qid.path
    local was = cat.ents[q]
    cat.nents = cat.nents + 1
    if better_ent(d, was) then
      d.candidates = (was and was.candidates or 0) + 1
      cat.ents[q] = d
    else
      was.candidates = was.candidates + 1
    end

  elseif kind == dat.Kdat then
    if op == dat.Oclearb or op == dat.Odelete then return end
    if #k ~= dat.Offksz or #v < dat.Ptrsz then return end
    local q, off = pack.unpackdatkey(k)
    local bp = pack.unpackbp(v)
    if bp.addr < 0 then return end
    local per = cat.data[q]
    if per == nil then per = {}; cat.data[q] = per end
    cat.ndat = cat.ndat + 1
    local was = per[off]
    -- the generation is the whole point: of several surviving copies of
    -- one block, the newest is the one the live tree pointed at
    if was == nil or bp.gen > was.gen then
      per[off] = { addr = bp.addr, hash = bp.hash, gen = bp.gen,
                   candidates = (was and was.candidates or 0) + 1 }
    else
      was.candidates = was.candidates + 1
    end

  elseif kind == dat.Kup then
    if #k ~= dat.Upksz then return end
    local q = sunpack(">i8", k, 2)
    local ok, up, name = pcall(pack.unpackdkey, v)
    if ok then cat.ups[q] = { up = up, name = name } end
  end
end

-- Walk the whole device. Returns a catalogue of everything legible.
function M.sweep(dev, opts)
  opts = opts or {}
  local blksz, how = M.blocksize(dev, opts)
  local geom = dat.geom(blksz, opts.bufspc)
  local size = dev:size()

  local cat = {
    blksz = blksz, how = how, geom = geom,
    ents = {}, data = {}, ups = {},
    nents = 0, ndat = 0,
    nblocks = 0, nparsed = 0, nbad = 0,
    stats = {},
  }

  local function bump(name)
    cat.stats[name] = (cat.stats[name] or 0) + 1
  end

  local addr = 0
  while addr + blksz <= size do
    cat.nblocks = cat.nblocks + 1
    local ok, s = pcall(dev.read, dev, addr, blksz)
    if not ok or s == nil or #s ~= blksz then
      bump("unreadable")
    else
      local ty = sunpack(">I2", s)
      if ty == dat.Tleaf or ty == dat.Tpivot then
        local b = blk.parse(s, { addr = addr, hash = -1, gen = -1 },
          geom, blk.GBnochk)
        if b == nil then
          cat.nbad = cat.nbad + 1
          bump("damaged")
        else
          cat.nparsed = cat.nparsed + 1
          bump(dat.typename[ty])
          for _, kv in ipairs(b.vals) do
            harvest(cat, kv.k, kv.v, dat.Oinsert)
          end
          -- a pivot's buffered messages are newer than anything below
          -- it, so they are worth as much as its values
          for _, m in ipairs(b.msgs) do
            harvest(cat, m.k, m.v, m.op)
          end
        end
      elseif dat.typename[ty] ~= nil and ty ~= dat.Tdat then
        bump(dat.typename[ty])
      else
        -- A data block has no header at all, so its first two bytes are
        -- whatever the file put there -- including the zeroes that free
        -- space and file holes are full of. Counting those as a type
        -- would be reading meaning into bytes that have none.
        bump("data or free")
      end
    end
    addr = addr + blksz
    if opts.progress and cat.nblocks % 4096 == 0 then
      opts.progress(cat.nblocks, size // blksz)
    end
  end
  return cat
end

--------------------------------------------------------------------------
-- rebuilding the namespace
--
-- Follow each entry's parent qid upwards. Anything that does not reach a
-- root, because its parent did not survive or because the chain loops,
-- is still recoverable -- the file's own data is indexed by qid, not by
-- path -- so it goes under lost+found rather than being dropped.

local function sanitize(name)
  if name == nil or name == "" then return "unnamed" end
  return (name:gsub("[/%z]", "_"))
end

function M.paths(cat)
  local paths = {}
  local orphans = {}

  local function resolve(q, depth)
    if paths[q] ~= nil then return paths[q] end
    local d = cat.ents[q]
    if d == nil then return nil end
    if depth > 128 then return nil end
    if d.up == -1 then
      paths[q] = (d.name == "") and "/" or ("/" .. sanitize(d.name))
      return paths[q]
    end
    local up = resolve(d.up, depth + 1)
    if up == nil then return nil end
    paths[q] = (up == "/" and "/" or (up .. "/")) .. sanitize(d.name)
    return paths[q]
  end

  for q in pairs(cat.ents) do
    if resolve(q, 0) == nil then
      orphans[#orphans + 1] = q
      paths[q] = ("/lost+found/%d/%s"):format(q, sanitize(cat.ents[q].name))
    end
  end

  -- data with no dirent at all: the file is gone but its bytes are not
  for q in pairs(cat.data) do
    if cat.ents[q] == nil then
      orphans[#orphans + 1] = q
      paths[q] = ("/lost+found/%d/data"):format(q)
    end
  end

  table.sort(orphans)
  return paths, orphans
end

--------------------------------------------------------------------------
-- reading a file back
--
-- Every block is checked against the hash the pointer carried. A block
-- that does not match is not silently handed back: it is reported, and
-- what goes in its place is the caller's choice.

function M.read(dev, cat, qid, opts)
  opts = opts or {}
  local blksz = cat.blksz
  local d = cat.ents[qid]
  local per = cat.data[qid] or {}

  local length = opts.length or (d and d.length)
  if length == nil then
    -- no dirent: take the extent of the blocks that survived
    length = 0
    for off in pairs(per) do
      if off + blksz > length then length = off + blksz end
    end
  end

  local out = {}
  local report = { holes = 0, damaged = 0, missing = 0, blocks = 0,
                   bytes = 0, length = length }
  local off = 0
  while off < length do
    local n = length - off
    if n > blksz then n = blksz end
    local e = per[off]
    local chunk
    if e == nil then
      report.holes = report.holes + 1
      chunk = ("\0"):rep(n)
    else
      report.blocks = report.blocks + 1
      local ok, s = pcall(dev.read, dev, e.addr, blksz)
      if not ok or s == nil or #s ~= blksz then
        report.missing = report.missing + 1
        chunk = ("\0"):rep(n)
      elseif e.hash ~= -1 and hash.blkhash(s) ~= e.hash then
        report.damaged = report.damaged + 1
        chunk = opts.keepdamaged and s:sub(1, n) or ("\0"):rep(n)
      else
        chunk = s:sub(1, n)
      end
    end
    out[#out + 1] = chunk
    report.bytes = report.bytes + #chunk
    off = off + n
  end
  return table.concat(out), report
end

--------------------------------------------------------------------------
-- writing it all out

local function mkdirp(path, mkdir)
  local acc = ""
  for part in path:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    mkdir(acc)
  end
end

-- opts.mkdir(path) and opts.write(path, s) do the work, so this module
-- still touches no filesystem of its own. bin/gefs.lua supplies them.
function M.extract(dev, cat, root, opts)
  opts = opts or {}
  local paths, orphans = M.paths(cat)
  local out = { files = 0, dirs = 0, bytes = 0,
                damaged = 0, holes = 0, missing = 0, orphans = #orphans }

  local order = {}
  for q in pairs(paths) do order[#order + 1] = q end
  table.sort(order, function(a, b) return paths[a] < paths[b] end)

  for _, q in ipairs(order) do
    local rel = paths[q]
    local d = cat.ents[q]
    local isdir = d ~= nil and (d.mode & dat.DMDIR) ~= 0
    if isdir then
      mkdirp(root .. rel, opts.mkdir)
      out.dirs = out.dirs + 1
    else
      local dir = (root .. rel):match("^(.*)/[^/]*$")
      if dir then mkdirp(dir, opts.mkdir) end
      local body, report = M.read(dev, cat, q, opts)
      opts.write(root .. rel, body)
      out.files = out.files + 1
      out.bytes = out.bytes + #body
      out.damaged = out.damaged + report.damaged
      out.holes = out.holes + report.holes
      out.missing = out.missing + report.missing
      if opts.onfile then opts.onfile(rel, report) end
    end
  end
  return out
end

--------------------------------------------------------------------------
-- a summary a person can read

function M.summary(cat)
  local nents, ndirs, ndata = 0, 0, 0
  local ambiguous = 0
  for _, d in pairs(cat.ents) do
    nents = nents + 1
    if d.mode & dat.DMDIR ~= 0 then ndirs = ndirs + 1 end
    if (d.candidates or 1) > 1 then ambiguous = ambiguous + 1 end
  end
  for _ in pairs(cat.data) do ndata = ndata + 1 end

  local kinds = {}
  for k, v in pairs(cat.stats) do kinds[#kinds + 1] = ("%s=%d"):format(k, v) end
  table.sort(kinds)

  return table.concat({
    ("block size %d (%s)"):format(cat.blksz, cat.how),
    ("%d blocks swept, %d parsed as metadata, %d damaged")
      :format(cat.nblocks, cat.nparsed, cat.nbad),
    ("%s"):format(table.concat(kinds, " ")),
    ("%d entries recovered (%d directories), %d with more than one version")
      :format(nents, ndirs, ambiguous),
    ("%d files have data blocks; %d entries and %d pointers were seen in all")
      :format(ndata, cat.nents, cat.ndat),
  }, "\n")
end

return M
