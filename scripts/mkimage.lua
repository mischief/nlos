#!/usr/bin/env lua5.4
-- mkimage.lua OUTPUT LUAOS_EFI LUA_FILE... -- 48M gpt disk, one esp
-- partition, fat via mtools (no root needed). lua files land at
-- /<name>; lib/*, bin/*, svc/* and etc/* land under the same name, so
-- a file's path in the namespace matches its path here.

local SGDISK = os.getenv("SGDISK") or "/sbin/sgdisk"
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

os.remove(out)
run("dd if=/dev/zero of=" .. qout .. " bs=512 count=93750 2>/dev/null")
run(quote(SGDISK) .. " -Z " .. qout .. " >/dev/null")
run(quote(SGDISK) .. " -N 1 " .. qout .. " >/dev/null")
run(quote(SGDISK) .. " -t 1:ef00 " .. qout .. " >/dev/null")
run(quote(SGDISK) .. " -c 1:\"EFI\" " .. qout .. " >/dev/null")

local drive = out .. "@@1M"	-- mtools' own syntax; not a shell-quoted path itself
local qdrive = quote(drive)

run("mformat -i " .. qdrive .. " -v EFI -F -h 32 -t 44 -n 64 -c 1")
run("mmd -i " .. qdrive .. " efi efi/boot lib bin svc etc")
run("mcopy -o -i " .. qdrive .. " " .. quote(efi) .. " ::efi/boot/" .. BOOT_EFI)

local function basename(path)
	return path:match("([^/]+)$") or path
end

for i = 3, #arg do
	local f = arg[i]
	local dest

	if f:find("/lib/", 1, true) then
		dest = "lib/" .. basename(f)
	elseif f:find("/bin/", 1, true) then
		dest = "bin/" .. basename(f)
	elseif f:find("/svc/", 1, true) then
		dest = "svc/" .. basename(f)
	elseif f:find("/etc/", 1, true) then
		dest = "etc/" .. basename(f)
	else
		dest = basename(f)
	end
	run("mcopy -o -i " .. qdrive .. " " .. quote(f) .. " ::" .. dest)
end
