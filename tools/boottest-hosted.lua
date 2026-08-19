#!/usr/bin/env lua5.4
-- boottest-hosted.lua BINARY PAYLOAD [--writable] [--blk] [--gefs]
--
-- runs one boot payload as proc 0 of a hosted machine and prints the
-- TAP it produced. --writable copies the tree into a scratch root
-- first: the default root is the working copy, and a test that writes
-- must not edit it. --blk and --gefs seed the disk.

local binary = arg[1]
local payload = arg[2]

if not binary or not payload then
	io.stderr:write("usage: boottest-hosted.lua BINARY PAYLOAD [flags]\n")
	os.exit(1)
end

local writable, wantblk, wantgefs, wantgui = false, false, false, false

-- the machine size a payload wants, where the default is more than it
-- should have to fill: the oom test has to reach the ceiling.
local mem = nil

for i = 3, #arg do
	if arg[i] == "--writable" then writable = true
	elseif arg[i] == "--blk" then wantblk = true
	elseif arg[i] == "--gefs" then wantgefs = true
	elseif arg[i] == "--gui" then wantgui = true
	elseif arg[i]:match("^%-%-mem=%d+$") then
		mem = arg[i]:match("%d+")
	else
		io.stderr:write("unknown flag: " .. arg[i] .. "\n")
		os.exit(1)
	end
end

local srcdir = os.getenv("MESON_SOURCE_ROOT") or "."
local toolsdir = arg[0]:match("^(.*)/[^/]+$") or "."

local function q(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run(cmd)
	if os.execute(cmd .. " >/dev/null 2>&1") ~= true then
		print("Bail out! harness command failed: " .. cmd)
		os.exit(1)
	end
end

-- a private directory for whatever this test needs to write
local tmp = os.tmpname()

os.remove(tmp)
run(("mkdir -p %s"):format(q(tmp)))

local function cleanup()
	os.execute(("rm -rf %s"):format(q(tmp)))
end

-- the root: the working copy read-only, or a copy of it to write in.
-- Only the directories a guest reaches by path are copied; test/ comes
-- too, since the payload itself is named out of it.
local root = srcdir

if writable then
	root = tmp .. "/root"
	run(("mkdir -p %s"):format(q(root)))
	for _, d in ipairs({ "init.lua", "lib", "bin", "task", "etc", "test" }) do
		run(("cp -a %s %s"):format(q(srcdir .. "/" .. d), q(root)))
	end
end

-- --blk seeds a small raw disk whose every sector says which sector it
-- is, so a read can prove it landed where it asked to.
local SECSZ, SECTORS = 512, 2048
local img = tmp .. "/disk.img"
local diskargs = ""

if wantblk then
	local f = assert(io.open(img, "wb"))

	for i = 0, SECTORS - 1 do
		local mark = ("sector %04d\n"):format(i)

		f:write(mark .. ("."):rep(SECSZ - #mark))
	end
	f:close()
	diskargs = " -d " .. q(img)
end

-- --gefs reams a volume and puts files in it that the guest did not
-- write, which is what its payload reads back. The constants match
-- tools/boottest-microvm.lua, because the payloads are the same files.
local GEFS_SIZE = 64 * 1024 * 1024
local GEFS_SMALL = "hello from gefs\n"
local GEFS_BIG = ("gefs"):rep(10000)

local function gefsput(path, content)
	local tf = tmp .. "/put.tmp"
	local f = assert(io.open(tf, "wb"))

	f:write(content)
	f:close()
	run(("lua5.4 %s put %s %s < %s"):format(q(toolsdir .. "/gefs.lua"),
	    q(img), q(path), q(tf)))
end

if wantgefs then
	local cli = q(toolsdir .. "/gefs.lua")

	run(("lua5.4 %s ream %s %d glenda"):format(cli, q(img), GEFS_SIZE))
	gefsput("/hello", GEFS_SMALL)
	run(("lua5.4 %s mkdir %s /dir"):format(cli, q(img)))
	gefsput("/dir/big", GEFS_BIG)
	diskargs = " -d " .. q(img)
end

-- meson names the payload through the build directory, so the path it
-- hands over is not literally under srcdir until both are resolved.
local function realpath(p)
	local f = assert(io.popen("realpath " .. q(p)))
	local r = f:read("l")

	f:close()
	return r
end

local abs = realpath(payload)
local base = realpath(srcdir)
local guestpath = abs:sub(#base + 1)

if abs:sub(1, #base) ~= base or guestpath == "" then
	print("Bail out! payload is not under the source root: " .. tostring(abs))
	cleanup()
	os.exit(1)
end

-- a window the test never shows: SDL's dummy driver gives a real
-- framebuffer with no display attached, which is what these payloads
-- read back from. Showing one would need a display to show it on.
local extra = (wantgui and " --gui" or "") ..
    (mem and (" -m " .. mem) or "")

local cmd = ("%s%s -r %s -p %s%s%s < /dev/null 2>&1"):format(
    wantgui and "SDL_VIDEO_DRIVER=dummy " or "", q(binary),
    q(root), q(guestpath), writable and " -w" or "", diskargs .. extra)

local p = assert(io.popen(cmd))
local out = p:read("a")

p:close()
cleanup()

-- the guest's console carries both the kernel's log lines and the
-- payload's TAP. Only TAP goes to meson; a kernel line becomes a
-- comment so a failure still has its diagnosis attached.
local sawplan = false

for line in out:gmatch("[^\n]*") do
	line = line:gsub("\r$", "")
	if line:match("^%d+%.%.%d+") then
		sawplan = true
		print(line)
	elseif line:match("^ok ") or line:match("^not ok ") or
	    line:match("^# ") or line:match("^Bail out!") then
		print(line)
	elseif line ~= "" then
		print("# " .. line)
	end
end

if not sawplan then
	print("Bail out! the guest produced no plan")
	os.exit(1)
end
