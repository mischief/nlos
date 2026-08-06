#!/usr/bin/env lua5.4
-- Build a FAT image for the esp32 luafs partition.
--
--	lua5.4 tools/mkfatimg.lua luafs.img 2M bin/=/bin
--
-- and then, from esp32/:
--
--	esptool.py write_flash 0x310000 luafs.img
--
-- The offset and the size come from esp32/partitions.csv and are not
-- read from it: this tool makes an image of the size it is told, and
-- flashing it to the wrong offset is a mistake no check here can catch.
--
-- The sector is the flash erase block, 4096 bytes, which is what makes
-- a sector write on the board exactly one erase and one program. Pass
-- --secsz for an image bound for something else, such as a card.
--
-- Each argument after the size is srcdir=/destdir. A directory is
-- copied whole and its subdirectories with it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local fat = require("fat")
local io_dev = require("gefs.io")

local function die(msg)
	io.stderr:write("mkfatimg: " .. msg .. "\n")
	os.exit(1)
end

local function usage()
	io.stderr:write(
	    "usage: mkfatimg.lua [--secsz N] [--label L] out.img size src=/dst ...\n")
	os.exit(2)
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
local nfiles, nbytes = 0, 0

for j = 3, #args do
	local src, dst = args[j]:match("^(.-)=(.*)$")

	if not src then
		die("expected src=/dst, got " .. args[j])
	end
	dst = dst:gsub("/+$", "")

	for _, rel in ipairs(walkdir(src)) do
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
	end
end

fs:sync()

local info = fs:info()

io.write(("%s: FAT%d, %d byte sectors, %d files, %d bytes\n"):format(
    out, info.type, secsz, nfiles, nbytes))

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
