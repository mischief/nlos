#!/usr/bin/env lua5.4
-- mkimage.lua OUTPUT LUAOS_EFI LUA_FILE... -- 48M gpt disk, one esp
-- partition, fat via mtools (no root needed). lua files land at
-- /<name>; lib/*, bin/*, task/* and etc/* land under the same name, so
-- a file's path in the namespace matches its path here.

local SFDISK = os.getenv("SFDISK") or "sfdisk"
local BOOT_EFI = os.getenv("BOOT_EFI") or "bootx64.efi"

local function quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run(cmd)
	local ok = os.execute(cmd)
	if ok ~= true then
		error("command failed: " .. cmd)
	end
end

local out = arg[1]
local efi = arg[2]
local qout = quote(out)

-- The FAT geometry below is fixed (-h 32 -t 44 -n 64 = 90112 sectors),
-- so the partition is sized to match it exactly rather than to whatever
-- is left over.
local PART_START = 2048
local PART_SECTORS = 32 * 44 * 64
local SECTORS = PART_START + PART_SECTORS + 34	-- + room for the backup GPT

os.remove(out)

-- sparse: nothing reads the zeroes, and mtools only materialises what it
-- writes.
run("truncate -s " .. (SECTORS * 512) .. " " .. qout)

-- sfdisk rather than sgdisk, and it is worth saying why, because sgdisk
-- is the more obvious tool and was here first.
--
-- sgdisk sleeps for one second on exit, unconditionally, with no flag to
-- stop it -- it is waiting for a kernel to reread a partition table,
-- which for a plain file means waiting for nobody. Four calls made four
-- seconds, and that WAS the build: the fifty mcopy calls that look like
-- the expensive part total 0.05s.
--
-- sfdisk does the same job in about 15ms, is util-linux rather than a
-- separate gptfdisk package, and --no-reread --no-tell-kernel say
-- explicitly that there is no kernel here to tell.
run("printf %s " ..
    quote("label: gpt\nstart=" .. PART_START .. ", size=" ..
        PART_SECTORS .. ", type=uefi, name=\"EFI\"\n") ..
    " | " .. quote(SFDISK) .. " --no-reread --no-tell-kernel -q " ..
    qout .. " >/dev/null")

local drive = out .. "@@1M"	-- mtools' own syntax; not a shell-quoted path itself
local qdrive = quote(drive)

run("mformat -i " .. qdrive .. " -v EFI -F -h 32 -t 44 -n 64 -c 1")
run("mmd -i " .. qdrive .. " efi efi/boot lib bin task etc")
run("mcopy -o -i " .. qdrive .. " " .. quote(efi) .. " ::efi/boot/" .. BOOT_EFI)

local function basename(path)
	return path:match("([^/]+)$") or path
end

-- keep whatever is below lib/ rather than flattening to the basename:
-- lib/crypto/sha256.lua has to stay reachable as require("crypto.sha256")
-- under LUA_PATH's /lib/?.lua, and flattening would break the name
-- rather than the file.
-- the four made by the mmd above already exist; only deeper ones need
-- creating, and mmd on an existing directory is an error rather than a
-- no-op.
local made = { ["efi"] = true, ["efi/boot"] = true, ["lib"] = true,
    ["bin"] = true, ["task"] = true, ["etc"] = true }

local function mkdirs(dest)
	local dir = dest:match("^(.*)/[^/]+$")

	if not dir or made[dir] then
		return
	end
	made[dir] = true
	run("mmd -i " .. qdrive .. " ::" .. dir)
end

local function under(f, top)
	local rest = f:match("/" .. top .. "/(.*)$")

	return rest and (top .. "/" .. rest) or nil
end

for i = 3, #arg do
	local f = arg[i]
	local dest = under(f, "lib") or under(f, "bin") or under(f, "task") or
	    under(f, "etc") or basename(f)

	mkdirs(dest)
	run("mcopy -o -i " .. qdrive .. " " .. quote(f) .. " ::" .. dest)
end
