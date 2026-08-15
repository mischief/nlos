#!/usr/bin/env lua5.4
-- Build a FAT image for the esp32 luafs partition.
--
--	lua5.4 tools/mkfatimg.lua luafs.img 2M bin/=/bin
--
-- The esp32 build calls it that way and flashes what it makes, taking
-- both the size and the offset from esp32/partitions.csv. Neither is
-- read here: this tool makes an image of the size it is told, and an
-- image written to the wrong offset is a mistake no check here can
-- catch.
--
-- The sector is the flash erase block, 4096 bytes, which is what makes
-- a sector write on the board exactly one erase and one program. Pass
-- --secsz for an image bound for something else, such as a card.
--
-- Each argument after the size is srcdir=/destdir. A directory is
-- copied whole and its subdirectories with it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

-- lib/fat holds a sector in a los.buf, which is a C module: built for
-- the host as build/los.so, beside the one the guest links in. Without
-- it this tool cannot load the filesystem it writes.
package.cpath = scriptdir .. "/../build/?.so;" .. package.cpath

local fat = require("fat")
local io_dev = require("gefs.io")

local function die(msg)
	io.stderr:write("mkfatimg: " .. msg .. "\n")
	os.exit(1)
end

local function usage()
	io.stderr:write(
	    "usage: mkfatimg.lua [--secsz N] [--label L] [--exclude-from F] " ..
	    "out.img size src=/dst ...\n")
	os.exit(2)
end

-- paths this image must not carry, one per line, as the firmware's own
-- embedded list names them. A file in both roots is worse than a file
-- in neither: the partition is mounted over the image and silently
-- wins, so an embedded copy is unreachable until the partition is
-- reflashed, and then it is whichever of the two is older.
local skip = {}

local function excludefrom(path)
	local f = io.open(path, "r")

	if not f then
		die("cannot read " .. path)
	end
	for l in f:lines() do
		l = l:gsub("%s+$", "")
		if l ~= "" then
			skip[l] = true
		end
	end
	f:close()
end

-- "2M", "512K", "1048576"
local function bytes(s)
	local n, suffix = s:match("^(%d+)([KMkm]?)$")

	if not n then
		die("cannot read a size from " .. s)
	end
	n = tonumber(n)
	if suffix == "K" or suffix == "k" then
		n = n * 1024
	elseif suffix == "M" or suffix == "m" then
		n = n * 1024 * 1024
	end
	return n
end

-- what is under a directory, as paths relative to it. ls is not in
-- stock lua, so this shells out; the alternative is luaposix, which the
-- rest of the tree does without.
-- A source that names nothing is a mistake, and it is refused here.
--
-- find says so on stderr and exits non-zero for a directory that is not
-- there, so the status is kept rather than discarded. Without this the
-- image is built, checks clean, flashes, and the board comes up with an
-- empty /bin -- a wrong path costs a boot to discover instead of a
-- line.
-- a plain file, told from a directory by whether it opens as one. No
-- stat in stock lua, and this is the same shell-out walkdir already is.
local function isfile(path)
	local f = io.open(path, "rb")

	if not f then
		return false
	end
	local ok = f:read(0) ~= nil

	f:close()
	return ok
end

local function walkdir(dir)
	local out = {}
	local p = io.popen(("find %q -type f -printf '%%P\\n'"):format(dir))

	if not p then
		die("cannot list " .. dir)
	end
	for line in p:lines() do
		if line ~= "" then
			out[#out + 1] = line
		end
	end

	local ok, how, code = p:close()

	if not ok then
		die(("%s: find %s %s"):format(dir, tostring(how),
		    tostring(code)))
	end
	if #out == 0 then
		die(dir .. ": no files under it")
	end
	table.sort(out)
	return out
end

local function slurp(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("a")

	f:close()
	return s
end

--------------------------------------------------------------------------

local args = {}
local secsz, label = 4096, "LUAOS"
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "--secsz" then
		i = i + 1
		secsz = tonumber(arg[i]) or die("--secsz wants a number")
	elseif a == "--label" then
		i = i + 1
		label = arg[i] or die("--label wants a name")
	elseif a == "--exclude-from" then
		i = i + 1
		excludefrom(arg[i] or die("--exclude-from wants a file"))
	elseif a:sub(1, 2) == "--" then
		usage()
	else
		args[#args + 1] = a
	end
	i = i + 1
end

if #args < 2 then
	usage()
end

local out = args[1]
local size = bytes(args[2])

local dev = assert(io_dev.create(out, size))
local fs = assert(fat.ream(dev, { label = label, secsz = secsz }))
local nfiles, nbytes, nskip = 0, 0, 0

for j = 3, #args do
	local src, dst = args[j]:match("^(.-)=(.*)$")

	if not src then
		die("expected src=/dst, got " .. args[j])
	end
	dst = dst:gsub("/+$", "")

	-- one file lands at exactly the name given, so a file whose name
	-- in the tree is not its name on the image -- the machine's own
	-- services list -- needs no directory built around it.
	if isfile(src) then
		local dir = dst:match("^(.*)/[^/]+$")

		if dir and dir ~= "" then
			assert(fs:mkdirp(dir))
		end

		local data = slurp(src)

		assert(fs:writefile(dst, data))
		nfiles = nfiles + 1
		nbytes = nbytes + #data
		goto continue
	end

	for _, rel in ipairs(walkdir(src)) do
		local from = src:gsub("/+$", "") .. "/" .. rel

		-- checked here rather than in walkdir, so its "no files
		-- under it" still means the path was wrong. A directory
		-- whose every file is embedded is a legitimate empty one.
		if skip[from] then
			nskip = nskip + 1
			goto next
		end

		local path = (dst == "" and "/" or dst .. "/") .. rel
		local dir = path:match("^(.*)/[^/]+$")
		local data = slurp(src .. "/" .. rel)

		if dir and dir ~= "" then
			-- mkdirp is content to find it already there
			assert(fs:mkdirp(dir))
		end
		assert(fs:writefile(path, data))
		nfiles = nfiles + 1
		nbytes = nbytes + #data
		::next::
	end

	::continue::
end

fs:sync()

local info = fs:info()

-- the skipped count is said out loud because it is the only evidence
-- the two roots stayed disjoint: zero where one was expected means the
-- exclusions missed, and the firmware's copies go back to being dead.
io.write(("%s: FAT%d, %d byte sectors, %d files, %d bytes%s\n"):format(
    out, info.type, secsz, nfiles, nbytes,
    nskip > 0 and (", " .. nskip .. " left to the image") or ""))

-- Say it back rather than trust it. The image is about to be flashed to
-- a board with no way to report a bad volume except by failing to boot,
-- so it is opened cold here and checked.
local check = fat.open(assert(io_dev.open(out, "r")))

if not check then
	die("the image does not open")
end

local problems = check:check()

if problems and #problems > 0 then
	for _, p in ipairs(problems) do
		io.stderr:write("mkfatimg: " .. tostring(p.what or p[1] or p) ..
		    "\n")
	end
	die("the image does not check clean")
end
