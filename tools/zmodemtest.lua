#!/usr/bin/env lua5.4
-- zmodemtest.lua ELF -- drive bin/rz.lua and bin/sz.lua from real lrzsz.
--
--	meson devenv -C build-microvm lua5.4 tools/zmodemtest.lua \
--	    build-microvm/luaos-microvm.elf
--
-- What this covers and test/host_lrzsz.lua cannot is the path either
-- side of the protocol: raw mode, readraw, the program ABI, and the
-- launcher starting rz by name.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../test/?.lua;" ..
    package.path

-- qemuarch and not tools/arch.lua: everything here is spawned by argv
-- rather than through a shell, which is the same reason test/test_9p.lua
-- uses it. It owns the one hostutil handle.
local qemuarch = require("qemuarch")
local hu = qemuarch.hostutil

-- every child is spawned by pid and killed by pid. A pattern match over
-- the process table would find another qemu on this machine, and the
-- one it finds is somebody's interactive session.
local kids = {}

local function spawn(argv, io_)
	local pid = hu.spawn(argv, io_)

	kids[#kids + 1] = pid
	return pid
end

local function reap()
	for _, pid in ipairs(kids) do
		hu.kill(pid)
		hu.wait(pid)
	end
	kids = {}
end

local elf = arg[1] or "build-microvm/luaos-microvm.elf"
local tree = scriptdir .. "/.."
local payload = tree .. "/test/boot/microvm_zmodemsh.lua"

local tmp = os.getenv("TMPDIR") or "/tmp"
local run = tmp .. "/zmodemtest." .. tostring(hu.getpid())
-- three directories: what the host sends from, the tree the guest boots
-- and writes into, and where lrz puts what comes back. Separate so a
-- name in two of them is the transfer and never a leftover.
local from = run .. ".from"
local root = run .. ".root"
local backdir = run .. ".back"
local NAME = "payload.bin"

local failures, checks = 0, 0

local function say(s)
	io.write(s, "\n")
	io.flush()
end

local function ok(cond, what)
	checks = checks + 1
	if not cond then
		failures = failures + 1
	end
	say((cond and "ok " or "not ok ") .. checks .. " - " .. what)
end

local function sh(cmd)
	return os.execute(cmd .. " >/dev/null 2>&1") and true or false
end

local function bail(why)
	say("Bail out! " .. why)
	reap()
	os.exit(1)
end

-- ---- the payload ----
--
-- Big enough to cross subpacket and window boundaries, and pseudorandom
-- so a stuck escape or a dropped ZDLE shows up in a comparison rather
-- than landing on an identical byte.
local SIZE = 24 * 1024
-- how long one transfer may take. Not the line's speed: the guest
-- writes each subpacket through a file server before it reads again.
local TIMEOUT_MS = tonumber(os.getenv("ZMODEM_TIMEOUT_MS")) or 300000
local parts, x = {}, 0x1234

for i = 1, SIZE do
	x = (x * 1103515245 + 12345) % 0x100000000
	parts[i] = string.char((x >> 16) & 0xff)
end

-- a copy of the tree rather than the tree itself: the share has to be
-- writable for rz to land anywhere, and a guest must not be able to
-- write into the working copy.
sh("mkdir -p " .. from .. " " .. root .. "/tmp " .. backdir)
assert(sh("cp -r " .. tree .. "/bin " .. tree .. "/lib " .. tree ..
    "/task " .. root), "staging the tree failed")

local f = assert(io.open(from .. "/" .. NAME, "wb"))

f:write(table.concat(parts))
f:close()

-- ---- boot ----
--
-- -serial pty and not a socket: sz and lrz both want a terminal they can
-- set raw, and qemu makes one directly. The path it picked is on its
-- stdout, which is why that is a file rather than /dev/null.
local qlog = run .. ".qemu"
local qout = assert(io.open(qlog, "w"))

local argv = {}

for _, a in ipairs(qemuarch.qemu()) do
	argv[#argv + 1] = a
end
for _, a in ipairs({
	"-M", "microvm,acpi=on,ioapic2=off,rtc=on",
	"-m", "256",
	"-nodefaults", "-no-user-config", "-no-reboot",
	"-display", "none", "-monitor", "none",
	"-kernel", elf,
	"-fw_cfg", "name=opt/org.luaos.test,file=" .. payload,
	"-fsdev", "local,id=fs0,security_model=none,path=" .. root,
	"-device", "virtio-9p-device,bus=virtio-mmio-bus.0," ..
	    "fsdev=fs0,mount_tag=hostshare",
	"-serial", "pty",
}) do
	argv[#argv + 1] = a
end
for _, a in ipairs(qemuarch.machine()) do
	argv[#argv + 1] = a
end

spawn(argv, { stdout = hu.fileno(qout), stderr = hu.fileno(qout) })
qout:close()

local function ptypath(secs)
	for _ = 1, secs * 10 do
		local h = io.open(qlog, "r")
		local text = h and h:read("a") or ""

		if h then
			h:close()
		end

		local p = text:match("redirected to (/dev/pts/%d+)")

		if p then
			return p
		end
		sh("sleep 0.1")
	end
	return nil
end

local ttypath = ptypath(20) or bail("qemu never reported a pty")

-- serial(), not io.open: it opens raw, so nothing on this side helps
-- with echo or line endings while a binary stream is going through.
local line = hu.serial(ttypath)
local fd = hu.fileno(line)

-- what the last program left on the line: its summary, a prompt, and
-- ZMODEM's trailing "OO". A transfer must start on a quiet line, which
-- is what a person watching the terminal does without noticing.
local function drain()
	for _ = 1, 100 do
		if hu.readable(fd, 0.05) then
			line:read(1)
		end
	end
end

local function typeline(s)
	line:write(s .. "\r")
	line:flush()
	sh("sleep 1")
end

-- session: lrzsz sets the line raw and flushes it, and a child without
-- a controlling terminal gets EIO for both rather than SIGTTOU.
local function runwith(argv, stderrpath)
	local eh = assert(io.open(stderrpath, "w"))
	local pid = spawn(argv, { stdin = fd, stdout = fd,
	    stderr = hu.fileno(eh), session = true })

	eh:close()

	-- a wall-clock deadline, not a loop count: what is being waited on
	-- is a transfer taking seconds, and an iteration count means
	-- whatever the sleep happens to be.
	local deadline = hu.now() + TIMEOUT_MS

	while hu.now() < deadline do
		local code = hu.poll(pid)

		if code then
			return code == 0
		end
		sh("sleep 0.1")
	end
	hu.kill(pid)
	say("# " .. argv[1] .. " did not finish within " ..
	    (TIMEOUT_MS / 1000) .. "s")
	return false
end

-- the guest boots straight into the launcher, so this waits for the
-- machine rather than for a prompt to type at.
sh("sleep 8")
-- rz writes to the working directory, and / is where the programs are.
typeline("cd /tmp")
drain()

-- ---- host -> guest ----
--
-- No "rz" typed here on purpose: sz writes that word itself and the
-- launcher runs it, which is what makes a terminal's send-file work
-- with nothing done at this end.
ok(runwith({ "sz", "-q", "-b", from .. "/" .. NAME }, run .. ".sz"),
    "host sz completed")
ok(sh("cmp -s " .. from .. "/" .. NAME .. " " .. root .. "/tmp/" .. NAME),
    "what rz wrote matches what sz sent")

-- ---- guest -> host ----
--
-- lrz writes into the directory it runs in, under the basename the
-- sender offers, so it is spawned with that as its cwd.
-- a bare return first: it costs a prompt, and a prompt is proof the
-- launcher is reading again rather than still finishing the last
-- program. Then drain that prompt, so the sender starts on a quiet
-- line.
typeline("")
drain()
typeline("sz /tmp/" .. NAME)
sh("sleep 1")
ok(runwith({ "sh", "-c", "cd " .. backdir .. " && exec lrz -q -b -O" },
    run .. ".lrz"), "host lrz completed")
ok(sh("cmp -s " .. from .. "/" .. NAME .. " " .. backdir .. "/" .. NAME),
    "what sz sent back matches byte for byte")

line:close()
reap()
say("1.." .. checks)

if failures > 0 then
	say("# artifacts in " .. run .. ".*")
end
os.exit(failures == 0 and 0 or 1)
