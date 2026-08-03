#!/usr/bin/env lua5.4
-- gefs on the host, with nothing booted: the port, the bare-io device,
-- and the crash safety, run under the host's own lua the way
-- test/host_tcp4.lua runs the TCP codec.
--
-- The standalone gefs tree keeps the exhaustive busted suite; this is
-- the part that earns its place in lua-os -- that the port loads and
-- runs here, that lib/gefs/io.lua is a working device, and that a commit
-- cut anywhere leaves the disk in one whole state or the other. The last
-- of those is done twice: once at block granularity through gefs.ram.cut
-- (raising), and once mid-block through a coroutine that yields inside a
-- write and is then abandoned -- a finer cut, against a real file that is
-- reopened cold.
--
-- No dependency beyond lua5.4: lib/tap.lua needs los.sys, so TAP is
-- emitted directly, the same way test/host_tcp4.lua does.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path

local h = require("gefs_helper")
local gefs = h.gefs

--------------------------------------------------------------------------
-- TAP

local count, failed = 0, 0
local function ok(cond, name)
  count = count + 1
  if cond then
    io.write(("ok %d - %s\n"):format(count, name))
  else
    failed = failed + 1
    io.write(("not ok %d - %s\n"):format(count, name))
  end
  return cond
end
local function diag(s) io.write("# " .. s .. "\n") end

-- a fresh scratch path per use, removed after
local function scratch()
  return os.tmpname()
end

--------------------------------------------------------------------------
-- A. the bare-io device

do
  local path = scratch()
  local dev = gefs.io.create(path, 1 << 20)
  ok(dev:size() == (1 << 20), "io.create makes a device of the asked size")

  -- a hole reads back as zeroes
  ok(dev:read(4096, 16) == string.rep("\0", 16),
    "an unwritten range reads back zero")

  dev:write(4096, "the quick brown fox")
  dev:sync()
  ok(dev:read(4096, 19) == "the quick brown fox",
    "a write reads back byte for byte")

  -- a read past the end is zero-filled to the length asked for
  ok(dev:read((1 << 20) - 8, 16) == string.rep("\0", 16),
    "a read across the end is zero-filled, not short")
  dev:close()

  -- reopened, the write is still there: it went to the file, not a buffer
  local d2 = gefs.io.open(path, "r")
  ok(d2:read(4096, 19) == "the quick brown fox",
    "the write survives a close and reopen")
  d2:close()
  os.remove(path)
end

--------------------------------------------------------------------------
-- B. a filesystem over the io device, reopened cold

do
  local path = scratch()
  local dev = gefs.io.create(path, 64 * 1024 * 1024)
  gefs.ream(dev, { user = "glenda", blksz = 16384 })

  local fs = gefs.open(dev)
  local m = fs:mount("main")
  m:createfile("/hello")
  m:writefile("/hello", "world\n")
  m:mkdir("/dir")
  m:createfile("/dir/deep")
  m:writefile("/dir/deep", ("payload"):rep(4000))
  fs:sync()
  ok(#fs:check() == 0, "a freshly written volume checks out")
  dev:close()

  -- a brand new device on the same bytes: nothing carried over in memory
  local rdev = gefs.io.open(path, "r")
  local fs2 = gefs.open(rdev, { rdonly = true })
  local m2 = fs2:mount("main")
  ok(m2:readfile("/hello") == "world\n",
    "a cold reopen reads the small file back")
  ok(m2:readfile("/dir/deep") == ("payload"):rep(4000),
    "a cold reopen reads the large file back")
  ok(#fs2:check() == 0, "the cold-reopened volume checks out")
  rdev:close()
  os.remove(path)
end

--------------------------------------------------------------------------
-- the staged work both crash walks cut through: a committed state, then
-- pending changes on top of it that the cut interrupts

local PATHS = { "/a", "/b", "/c", "/d/e" }

local function contents(m)
  local out = {}
  for _, p in ipairs(PATHS) do
    local d = m:walk(p)
    out[p] = d and m:read(d, 0, d.length) or false
  end
  return out
end

-- commit a known state onto dev, return the mount and the committed
-- contents; caller then stages pending changes and cuts the sync
local function commitbase(fs)
  local m = fs:mount("main")
  m:createfile("/a"); m:writefile("/a", ("one"):rep(100))
  m:createfile("/b"); m:writefile("/b", ("two"):rep(9000))
  m:mkdir("/d"); m:createfile("/d/e"); m:writefile("/d/e", "deep")
  fs:sync()
  return m, contents(m)
end

local function stage(m)
  m:writefile("/a", ("changed"):rep(3000))
  m:createfile("/c"); m:writefile("/c", ("new"):rep(6000))
  m:removepath("/d/e")
end

-- what a completed commit of that staged work looks like
local function newstate()
  local dev = gefs.ram.new(128 * 1024 * 1024, 16384)
  gefs.ream(dev, { user = "glenda", blksz = 16384 })
  local fs = gefs.open(dev)
  local m = commitbase(fs)
  stage(m)
  fs:sync()
  return contents(fs:mount("main"))
end

local function classify(got, old, new)
  local isold, isnew = true, true
  for _, p in ipairs(PATHS) do
    if got[p] ~= old[p] then isold = false end
    if got[p] ~= new[p] then isnew = false end
  end
  return isold, isnew
end

--------------------------------------------------------------------------
-- C. block-granularity power cut (gefs.ram.cut), the crash_spec case

do
  local NEW = newstate()

  -- measure the commit on a throwaway copy so the cut points can walk it
  local cost
  do
    local dev = gefs.ram.new(128 * 1024 * 1024, 16384)
    gefs.ream(dev, { user = "glenda", blksz = 16384 })
    local fs = gefs.open(dev)
    local m = commitbase(fs); stage(m)
    local before = dev.nwrite
    fs:sync()
    cost = dev.nwrite - before
  end
  ok(cost > 8, ("a commit is worth cutting (%d writes)"):format(cost))

  local mixed, unreadable = 0, 0
  for cut = 1, cost do
    local dev = gefs.ram.new(128 * 1024 * 1024, 16384)
    gefs.ream(dev, { user = "glenda", blksz = 16384 })
    local fs = gefs.open(dev)
    local m, old = commitbase(fs)
    stage(m)
    fs.dev = gefs.ram.cut(dev, cut)
    pcall(fs.sync, fs)

    local fs2, err = gefs.open(dev)
    if fs2 == nil then
      unreadable = unreadable + 1
      diag(("cut %d: no readable volume: %s"):format(cut, tostring(err)))
    else
      if #fs2:check() ~= 0 then unreadable = unreadable + 1 end
      local isold, isnew = classify(contents(fs2:mount("main")), old, NEW)
      if not (isold or isnew) then mixed = mixed + 1 end
    end
  end
  ok(mixed == 0, "block-cut: every cut point left old or new, never a mixture")
  ok(unreadable == 0, "block-cut: every cut point left a sound volume")
end

--------------------------------------------------------------------------
-- D. a torn block is refused, not believed (crash_spec)

do
  local m, fs, dev = h.mounted()
  m:createfile("/f"); m:writefile("/f", ("payload"):rep(5000))
  fs:sync()
  local want = m:readfile("/f")
  local blksz = fs.geom.blksz

  local touched, refused, wrong = 0, 0, 0
  for bi, s in pairs(dev.blocks) do
    dev.blocks[bi] = string.char(s:byte(1) ~ 0x40) .. s:sub(2)
    local okr, got = pcall(function()
      return gefs.open(dev):mount("main"):readfile("/f")
    end)
    if okr and got ~= nil then
      if got ~= want then wrong = wrong + 1 end
    else
      refused = refused + 1
    end
    dev.blocks[bi] = s
    touched = touched + 1
  end
  ok(touched > 10 and wrong == 0,
    ("torn block: flipped %d blocks, none returned wrong bytes"):format(touched))
  ok(refused > 0, "torn block: the damage was noticed")
  ok(gefs.open(dev):mount("main"):readfile("/f") == want,
    "torn block: undamaged, the volume reads fine again")
end

--------------------------------------------------------------------------
-- E. mid-write power cut through a coroutine, against a real file
--
-- The finer cut: the device yields inside a block write, so a cut can
-- land mid-block and leave it torn, and the file is reopened cold from a
-- fresh device on the real bytes. Same promise as C -- old or new, never
-- mixed -- proven one chunk at a time.

do
  local NEW = newstate()

  -- lay down the committed base on a real file once, then copy those
  -- bytes for each attempt so the baseline is not re-reamed every cut
  local base = scratch()
  local old
  do
    local dev = gefs.io.create(base, 64 * 1024 * 1024)
    gefs.ream(dev, { user = "glenda", blksz = 4096 })
    local fs = gefs.open(dev)
    local m
    m, old = commitbase(fs)
    dev:close()
  end

  local function copyfile(src, dst)
    local a = assert(io.open(src, "rb"))
    local b = assert(io.open(dst, "wb"))
    while true do
      local chunk = a:read(1 << 20)
      if chunk == nil then break end
      b:write(chunk)
    end
    a:close(); b:close()
  end

  -- one attempt: restore the base, stage, arm, sync inside a coroutine
  -- and abandon after k yields, then cold-reopen and read
  local function attempt(k)
    local path = scratch()
    copyfile(base, path)
    local dev = h.cocut(gefs.io.open(path), 1024)
    local fs = gefs.open(dev)
    stage(fs:mount("main"))
    local yields, cut = h.crashafter(function(d)
      d:arm(); fs:sync()
    end, dev, k)
    dev.dev:close()

    local rdev = gefs.io.open(path)
    local fs2, err = gefs.open(rdev)
    local res
    if fs2 == nil then
      res = { readable = false, err = err }
    else
      local sound = #fs2:check() == 0
      local isold, isnew = classify(contents(fs2:mount("main")), old, NEW)
      res = { readable = true, sound = sound, old = isold, new = isnew }
    end
    rdev:close()
    os.remove(path)
    return yields, cut, res
  end

  -- measure the whole commit's yield count
  local cost = select(1, attempt(1 << 30))
  ok(cost > 8, ("mid-write commit yields %d times"):format(cost))

  local mixed, unsound, cutcount = 0, 0, 0
  for k = 1, cost do
    local _, cut, res = attempt(k)
    if cut then cutcount = cutcount + 1 end
    if not res.readable then
      unsound = unsound + 1
      diag(("cut %d: unreadable: %s"):format(k, tostring(res.err)))
    else
      if not res.sound then unsound = unsound + 1 end
      if not (res.old or res.new) then mixed = mixed + 1 end
    end
  end
  ok(cutcount == cost, "mid-write: every yield was an abandonable cut point")
  ok(mixed == 0, "mid-write: every cut left old or new, never a mixture")
  ok(unsound == 0, "mid-write: every cut left a sound, readable volume")

  os.remove(base)
end

--------------------------------------------------------------------------
-- F. the random-walk torture, a few configurations

do
  local run = require("gefs_torture").run
  local c1 = run({ seed = 1, steps = 500 })
  ok((c1.write or 0) > 50 and (c1.remove or 0) > 10,
    "torture seed 1 exercised writes and removes")

  local c2 = run({ seed = 2, steps = 400, blksz = 4096 })
  ok((c2.write or 0) > 50, "torture seed 2 survived a deep tree (4k blocks)")

  local c3 = run({ seed = 3, steps = 400, snapshots = true, reopen = true })
  ok((c3.snap or 0) > 2 and (c3.reopen or 0) > 1,
    "torture seed 3 survived snapshots and reopens")
end

--------------------------------------------------------------------------
-- G. lib/gefsfs.lua: the volume presented as a dev backend
--
-- The adapter that task/gefssrv.lua serves. dev.lua wants los.sys for one
-- constant (MAXMSG), which the host has no kernel to provide, so it is
-- stubbed -- the mapping itself touches nothing else of the kernel.

do
  package.loaded["los.sys"] = { MAXMSG = 8192 }
  local gefsfs = require("gefsfs")

  local m = h.mounted()
  m:createfile("/file"); m:writefile("/file", "contents\n")
  m:mkdir("/sub"); m:createfile("/sub/inner"); m:writefile("/sub/inner", "deep")

  local B = gefsfs.new(m)

  local root = B.attach()
  ok(B.stat(root).dir, "backend: the root is a directory")

  local fh = B.walk(root, "file")
  local st = B.stat(fh)
  ok(st.name == "file" and st.size == 9 and not st.dir,
    "backend: stat a walked file")
  ok(B.read(fh, 0, 9) == "contents\n", "backend: read a file")
  ok(B.read(fh, 9, 8) == "", "backend: read at eof is empty")

  -- write through the backend, read it back through a fresh walk
  ok(B.write(fh, 0, "CONTENTS") == 8, "backend: write returns the count")
  ok(B.read(B.walk(root, "file"), 0, 9) == "CONTENTS\n",
    "backend: the write is visible on a re-walk")

  -- create through the backend
  local nh = B.create(root, "made", "rw")
  B.write(nh, 0, "fresh")
  ok(B.read(B.walk(root, "made"), 0, 5) == "fresh",
    "backend: create then write a new file")
  ok(not select(1, pcall(B.create, root, "made", "rw")),
    "backend: creating an existing name is refused")

  -- directories: walk into one, list it, refuse to read it
  local sh = B.walk(root, "sub")
  ok(B.stat(sh).dir, "backend: walk into a subdirectory")
  ok(not select(1, pcall(B.read, sh, 0, 1)),
    "backend: reading a directory is refused")
  local names = {}
  for _, e in ipairs(B.readdir(sh)) do names[e.name] = e end
  ok(names.inner and names.inner.size == 4 and not names.inner.dir,
    "backend: readdir lists a directory's entries")

  -- ".." off the root stays at the root; a missing name raises
  ok(B.stat(B.walk(root, "..")).dir, "backend: .. at the root stays put")
  ok(not select(1, pcall(B.walk, root, "nope")),
    "backend: walking a missing name raises")

  -- remove
  B.remove(B.walk(root, "made"))
  ok(m:walk("/made") == nil, "backend: remove takes the file out of the tree")

  package.loaded["los.sys"] = nil
end

io.write(("1..%d\n"):format(count))
if failed > 0 then
  diag(("%d of %d failed"):format(failed, count))
  os.exit(1)
end
