#!/usr/bin/env lua5.4
-- A command line over a gefs volume in a file. Useful for looking at
-- what the library produced, and for making a volume to hand to
-- something else.
--
--      gefs ream   disk.img [size] [user]
--      gefs ls     disk.img [path] [-s snap]
--      gefs cat    disk.img path  [-s snap]
--      gefs put    disk.img path < file
--      gefs mkdir  disk.img path
--      gefs rm     disk.img path
--      gefs snap   disk.img name
--      gefs unsnap disk.img name
--      gefs snaps  disk.img
--      gefs check  disk.img
--      gefs fsck   disk.img [-fix]
--      gefs salvage disk.img outdir [-b size] [-keep]
--      gefs stat   disk.img
--      gefs grow   disk.img [size] [-n arenas]
--      gefs shrink disk.img

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/../lib/?.lua;" .. package.path

-- lib/gefs hashes blocks with the C metrohash64 and keeps no lua
-- fallback, so gefs.so has to be findable from wherever this is run.
-- LUAOS_BUILD says where; without it the default "./?.so" still answers
-- when the caller's directory IS a build directory, which is what meson
-- does and why the suite did not notice this was needed.
local build = os.getenv("LUAOS_BUILD")

if build then
	package.cpath = build .. "/?.so;" .. package.cpath
end

local gefs = require("gefs")
local sys_stat = (select(2, pcall(require, "posix.sys.stat")))
local dat = gefs.dat

local function die(fmt, ...)
	io.stderr:write("gefs: " .. fmt:format(...) .. "\n")
	os.exit(1)
end

local function usage()
	io.stderr:write([[
usage: gefs command disk.img [args]

  ream   disk.img [size] [user]   make a volume, default 1G
  ls     disk.img [path]          list a directory
  cat    disk.img path            write a file to stdout
  put    disk.img path            read stdin into a file, creating it
  mkdir  disk.img path            make a directory
  rm     disk.img path            remove a file or an empty directory
  snap   disk.img name            label the current state
  unsnap disk.img name            drop a label and reclaim its blocks
  snaps  disk.img                 list the labels
  check  disk.img                 verify the trees
  fsck   disk.img                 that, plus reachability and the namespace
  salvage disk.img outdir         recover files from an image that will
                                  not open, without reading a superblock
  stat   disk.img                 report the superblock and the arenas
  grow   disk.img [size]          extend the image to size (if given), then
                                  add arenas to fill the device
  shrink disk.img                 drop empty trailing arenas; the volume
                                  shrinks, the image file is left as-is

  -s name   operate on a snapshot rather than main
  -n count  grow: arenas to add (default 4)
  -fix      fsck: return leaked blocks to the free list
  -b size   salvage: the block size, if it cannot be worked out
  -keep     salvage: write damaged blocks out rather than zeroes
]])
	os.exit(2)
end

-- pull the flags out, leaving the positional arguments
local snap = "main"
local flags = {}
local args = {}
do
	local i = 1
	while arg[i] do
		if arg[i] == "-s" then
			i = i + 1
			snap = arg[i] or usage()
		elseif arg[i] == "-b" then
			i = i + 1
			flags.blksz = tonumber(arg[i]) or usage()
		elseif arg[i] == "-fix" then
			flags.fix = true
		elseif arg[i] == "-keep" then
			flags.keep = true
		elseif arg[i] == "-o" then
			i = i + 1
			flags.off = tonumber(arg[i]) or usage()
		elseif arg[i] == "-l" then
			i = i + 1
			flags.len = tonumber(arg[i]) or usage()
		elseif arg[i] == "-n" then
			i = i + 1
			flags.narena = tonumber(arg[i]) or usage()
		else
			args[#args + 1] = arg[i]
		end
		i = i + 1
	end
end

local cmd = args[1]
local img = args[2]
if cmd == nil or img == nil then
	usage()
end

-- -o off -l len operate on a slice of the file, so a volume in a
-- partition of a larger disk is addressed the same as one that owns its
-- whole device. The disk is opened, never truncated, so the table around
-- the partition survives.
local function opendev(mode)
	local dev, err = gefs.io.open(img, mode or "rw")
	if dev == nil then
		die("cannot open %s: %s", img, tostring(err))
	end
	if flags.off then
		if not flags.len then
			die("-o needs -l (the partition length)")
		end
		return gefs.slice(dev, flags.off, flags.len)
	end
	return dev
end

local function openfs()
	local ok, fs = pcall(gefs.open, opendev())
	if not ok then
		die("%s", tostring(fs))
	end
	return fs
end

local function modestr(d)
	local s = (d.mode & dat.DMDIR ~= 0) and "d" or "-"
	local bits = "rwxrwxrwx"
	for i = 1, 9 do
		s = s .. (((d.mode >> (9 - i)) & 1) == 1 and bits:sub(i, i) or "-")
	end
	return s
end

local cmds = {}

function cmds.ream()
	local size = tonumber(args[3]) or (1024 * 1024 * 1024)
	local user = args[4] or os.getenv("USER") or "glenda"
	local dev
	if flags.off then
		-- ream into an existing disk's partition, leaving the rest alone
		dev = opendev("rw")
		size = flags.len
	else
		local err
		dev, err = gefs.io.create(img, size)
		if dev == nil then
			die("cannot create %s: %s", img, tostring(err))
		end
	end
	gefs.ream(dev, { user = user })
	io.write(("reamed %s: %d bytes, user %s\n"):format(img, size, user))
end

function cmds.ls()
	local fs = openfs()
	local m = fs:mount(snap)
	local path = args[3] or "/"
	local ents, err = m:ls(path)
	if ents == nil then
		die("%s: %s", path, err)
	end
	for _, e in ipairs(ents) do
		io.write(("%s %8d %s\n"):format(modestr(e), e.length, e.name))
	end
end

function cmds.cat()
	local fs = openfs()
	local m = fs:mount(snap)
	local path = args[3] or usage()
	local d = m:walk(path)
	if d == nil then
		die("%s: does not exist", path)
	end
	-- a chunk at a time, so a big file does not become a big string
	local off = 0
	while off < d.length do
		local s = m:read(d, off, 1 << 20)
		if #s == 0 then
			break
		end
		io.write(s)
		off = off + #s
	end
end

function cmds.put()
	local fs = openfs()
	local m = fs:mount(snap)
	local path = args[3] or usage()
	if m:walk(path) == nil then
		local _, err = m:createfile(path)
		if err then
			die("%s: %s", path, err)
		end
	end
	local d = assert(m:walk(path))
	m:truncate(d, 0)
	local off = 0
	while true do
		local s = io.read(1 << 20)
		if s == nil or #s == 0 then
			break
		end
		m:write(d, off, s)
		off = off + #s
	end
	fs:sync()
	io.write(("wrote %d bytes to %s\n"):format(off, path))
end

function cmds.mkdir()
	local fs = openfs()
	local m = fs:mount(snap)
	local _, err = m:mkdir(args[3] or usage())
	if err then
		die("%s", err)
	end
	fs:sync()
end

function cmds.rm()
	local fs = openfs()
	local m = fs:mount(snap)
	local _, err = m:removepath(args[3] or usage())
	if err then
		die("%s", err)
	end
	fs:sync()
end

function cmds.snap()
	local fs = openfs()
	fs:mount("main")
	fs:snapshot("main", args[3] or usage(), 0)
	fs:sync()
end

function cmds.unsnap()
	local fs = openfs()
	fs:delsnapshot(args[3] or usage())
	fs:sync()
end

function cmds.snaps()
	local fs = openfs()
	local s = fs:btscan(fs.snap, string.pack(">I1", dat.Klabel))
	for kv in s:iter() do
		local gen, flg = gefs.pack.kv2lbl(kv.v)
		io.write(("%-20s gen %-6d %s\n"):format(kv.k:sub(2), gen, (flg & dat.Lmut ~= 0) and "mutable" or "frozen"))
	end
	s:close()
end

function cmds.check()
	local fs = openfs()
	local fail = fs:check()
	for _, f in ipairs(fail) do
		io.write("  ", f, "\n")
	end
	io.write(("%d problems\n"):format(#fail))
	os.exit(#fail == 0 and 0 or 1)
end

function cmds.fsck()
	local fs = openfs()
	-- mount everything first: a mount's root only reaches the snapshot
	-- tree at a commit, and the trees nobody names are still worth
	-- checking
	local s = fs:btscan(fs.snap, string.pack(">I1", dat.Klabel))
	local names = {}
	for kv in s:iter() do
		names[#names + 1] = kv.k:sub(2)
	end
	s:close()
	for _, n in ipairs(names) do
		pcall(fs.mount, fs, n)
	end

	local fail, report = fs:fsck({ fix = flags.fix, maxleaks = 40 })
	for _, f in ipairs(fail) do
		io.write("  ", f, "\n")
	end
	io.write(("%d problems, %d leaked blocks"):format(#fail, #report.leaked))
	if report.reclaimed > 0 then
		io.write((", %d reclaimed (%d bytes)"):format(report.reclaimed, report.reclaimed * fs.geom.blksz))
	elseif #report.leaked > 0 and not flags.fix then
		io.write("; run with -fix to reclaim them")
	end
	io.write("\n")
	os.exit(#fail == 0 and 0 or 1)
end

function cmds.salvage()
	local outdir = args[3] or usage()
	local salvage = require("gefs.salvage")
	local dev = opendev("r")

	io.stderr:write("sweeping...\n")
	local cat = salvage.sweep(dev, {
		blksz = flags.blksz,
		-- progress goes to stderr so that redirecting stdout gets the
		-- report and nothing else
		progress = function(n, of)
			io.stderr:write(("\r  %d/%d blocks"):format(n, of))
		end,
	})
	io.stderr:write("\r\27[K")
	io.write(salvage.summary(cat), "\n\n")

	local mkdir = function(p)
		if sys_stat then
			sys_stat.mkdir(p, tonumber("755", 8))
		end
	end
	local write = function(p, s)
		local f = assert(io.open(p, "wb"))
		f:write(s)
		f:close()
	end

	local damaged = {}
	local out = salvage.extract(dev, cat, outdir, {
		mkdir = mkdir,
		write = write,
		keepdamaged = flags.keep,
		onfile = function(rel, r)
			if r.damaged > 0 or r.missing > 0 then
				damaged[#damaged + 1] = ("%s: %d damaged, %d unreadable of %d blocks"):format(
					rel,
					r.damaged,
					r.missing,
					r.blocks
				)
			end
		end,
	})

	for _, d in ipairs(damaged) do
		io.write("  ", d, "\n")
	end
	io.write(("\n%d files and %d directories, %d bytes\n"):format(out.files, out.dirs, out.bytes))
	io.write(
		("%d damaged blocks, %d unreadable, %d holes, %d orphans\n"):format(
			out.damaged,
			out.missing,
			out.holes,
			out.orphans
		)
	)
end

function cmds.stat()
	local fs = openfs()
	io.write(("blocksize:  %d\n"):format(fs.geom.blksz))
	io.write(("bufferspc:  %d\n"):format(fs.geom.bufspc))
	io.write(("arenas:     %d\n"):format(fs.narena))
	io.write(("snaptree:   %d, height %d\n"):format(fs.snap.bp.addr, fs.snap.ht))
	io.write(("next qid:   %d\n"):format(fs.nextqid))
	io.write(("next gen:   %d\n"):format(fs.nextgen))
	local size, used = 0, 0
	for i = 1, fs.narena do
		size = size + fs.arenas[i].size
		used = used + fs.arenas[i].used
	end
	io.write(("space:      %d of %d bytes used (%.1f%%)\n"):format(used, size, 100 * used / size))
end

local function mib(n) return n / (1024 * 1024) end

-- grow onto a bigger device. With a size, extend the image first -- a
-- sparse write, the same one gefs.io.create uses -- then add arenas to
-- fill it. A partition slice (-o/-l) is a fixed length and cannot be
-- extended. Without a size, add arenas into whatever room the device
-- already has. Fs:grow fills up to dev:size() and never calls resize, so
-- no host truncate is needed here.
function cmds.grow()
	local size = tonumber(args[3])
	if size ~= nil then
		if flags.off then
			die("cannot resize a partition slice; omit size or drop -o/-l")
		end
		local f = assert(io.open(img, "r+b"))
		local cur = f:seek("end")
		if size < cur then
			f:close()
			die("%s is already %d bytes", img, cur)
		end
		if size > cur then
			f:seek("set", size - 1)
			f:write("\0")
			f:flush()
		end
		f:close()
	end
	local fs = openfs()
	local was = fs.narena
	local n, bytes = fs:grow({ narena = flags.narena })
	io.write(("%d arenas -> %d, %.1f MiB added, image %.1f MiB\n")
		:format(was, fs.narena, mib(bytes), mib(fs.dev:size())))
	if n == 0 then
		os.exit(1)
	end
end

-- drop empty trailing arenas. The trees have to be mounted first, or the
-- reachability sweep sees every block they own as nobody's. The volume
-- shrinks; the image file is NOT truncated -- io.lua has no resize (a
-- fixed block device cannot be cut, and there is no luaposix here to
-- truncate a file), and a smaller volume on an oversized file is a
-- correct, re-growable state.
function cmds.shrink()
	local fs = openfs()
	local s = fs:btscan(fs.snap, string.pack(">I1", dat.Klabel))
	local names = {}
	for kv in s:iter() do
		names[#names + 1] = kv.k:sub(2)
	end
	s:close()
	for _, nm in ipairs(names) do
		pcall(fs.mount, fs, nm)
	end

	local was = fs.narena
	local n, bytes, why = fs:shrink({})
	if n == 0 then
		io.write(("nothing to drop: %s\n"):format(tostring(why)))
		os.exit(1)
	end
	io.write(("%d arenas -> %d, %.1f MiB given back (image file unchanged)\n")
		:format(was, fs.narena, mib(bytes)))
	if why ~= nil then
		io.write(("stopped at: %s\n"):format(why))
	end
end

local fn = cmds[cmd]
if fn == nil then
	usage()
end
local ok, err = pcall(fn)
if not ok then
	die("%s", tostring(err))
end
