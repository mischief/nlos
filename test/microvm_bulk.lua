#!/usr/bin/env lua5.4
-- bulk transfer over the lua tcp stack, with the host as the server.
--
-- The counterpart to test/microvm_http.lua, in the other direction. That
-- one gives the host a door into the guest with hostfwd; this needs no
-- forwarding at all, because qemu's user networking already proxies a
-- guest's connection to 10.0.2.2 onto the host's loopback -- which is
-- where test/hostserver.lua binds.
--
-- Why it exists: every other test moves a few kilobytes and asks whether
-- the protocol is right. Several megabytes each way asks whether it
-- works. It is thousands of segments, a receive window that closes and
-- reopens continuously, and a send buffer that fills -- and none of that
-- is reachable from a five-byte echo.
--
-- The guest emits TAP on the serial line, which this passes through, so
-- the assertions read as the guest's rather than being re-derived here.
-- What this file asserts on its own account is only what the guest
-- cannot see: that the upload arrived on the host, and how much of it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

-- tools/ too: fwcfg.lua is shared with the boot harnesses.
local toolsdir = scriptdir .. "/../tools"
package.path = scriptdir .. "/?.lua;" .. package.path .. ";" .. toolsdir .. "/?.lua"

local server = require("hostserver")
local hostutil = assert(package.loadlib(os.getenv("HOSTUTIL_SO") or
    "./hostutil.so", "luaopen_hostutil"))()

local elf = arg[1]
local payload = arg[2]

-- Big enough to need flow control, small enough that a test suite is
-- not a coffee break. Two megabytes is about fifteen hundred segments
-- each way.
--
-- The download is the slower half by a wide margin, and not because of
-- the network: the guest hashes what it receives, and sha256 in lua
-- runs about 660KB/s where the stack itself moves 8MB/s over slirp.
-- Hashing is the point -- a length check alone would not notice a
-- duplicated segment -- so the size is chosen around it.
local DOWN = tonumber(os.getenv("BULK_DOWN") or "2097152")
local UP = tonumber(os.getenv("BULK_UP") or "2097152")

local failed = 0
local count = 0

local function ok(cond, name)
	count = count + 1
	if not cond then
		failed = failed + 1
	end
	print((cond and "ok" or "not ok") .. " " .. count .. " - " .. name)
	return cond
end

local function diag(s)
	for line in (tostring(s):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			print("# " .. line)
		end
	end
end

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
end

local function readfile(path)
	local f = io.open(path, "rb")

	if not f then
		return ""
	end

	local d = f:read("a")

	f:close()
	return d
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")
local serial = tmp .. "/serial.log"

local function cleanup(pid)
	if pid then
		hostutil.kill(pid)
		hostutil.wait(pid)
	end
	os.execute("rm -rf '" .. tmp .. "'")
end

local lfd, port = hostutil.listen_tcp(4)

if not lfd then
	print("1..1")
	print("not ok 1 - could not listen: " .. tostring(port))
	os.exit(1)
end

-- the guest carries its parameters, because fw_cfg injects one file and
-- there is nowhere else to put them.
local src = readfile(scriptdir .. "/boot/microvm_bulk.lua")

src = src:gsub("@@PORT@@", tostring(port))
src = src:gsub("@@DOWN@@", tostring(DOWN))
src = src:gsub("@@UP@@", tostring(UP))

local genpath = tmp .. "/bulk.lua"
local gf = assert(io.open(genpath, "wb"))

gf:write(src)
gf:close()

-- the fw_cfg keys come from tools/fwcfg.lua, which the boot harnesses
-- share: a list rather than table.unpack, which mid-constructor would
-- expand to one argument.
local argv = {
	"qemu-system-x86_64",
	"-M", "microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm", "-cpu", "host", "-m", "256",
	"-kernel", elf,
}
for _, a in ipairs(require("fwcfg").args(genpath,
    { services = true, dir = tmp, tools = toolsdir })) do
	argv[#argv + 1] = a
end
for _, a in ipairs({
	"-device", "virtio-rng-device,bus=virtio-mmio-bus.1",
	"-netdev", "user,id=n0",
	"-device", "virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2",
	"-nodefaults", "-no-user-config", "-no-reboot", "-display", "none",
	"-serial", "file:" .. serial,}) do
	argv[#argv + 1] = a
end

local pid = hostutil.spawn(argv)

if not pid then
	print("1..1")
	print("not ok 1 - qemu did not start")
	cleanup(nil)
	os.exit(1)
end

-- ---- serve the guest ----
--
-- Two connections, in order, and the guest says which is which on the
-- connection itself: a stack that muddled them would otherwise look
-- exactly like one that worked.
local uploaded = 0
local served = 0

for _ = 1, 2 do
	local cfd = hostutil.accept(lfd, 60)

	if not cfd then
		break
	end

	local cmd = hostutil.recv(cfd, 256, 30) or ""

	if cmd:match("^chargen") then
		local want = tonumber(cmd:match("chargen%s+(%d+)")) or DOWN

		server.chargen(hostutil, cfd, want)
		served = served + 1
	elseif cmd:match("^discard") then
		uploaded = server.discard(hostutil, cfd, 30)
		served = served + 1
	end
	hostutil.close(cfd)
end

hostutil.close(lfd)

-- the guest powers itself off when its TAP is done; wait for that
-- rather than killing it, or its last lines are lost.
local deadline = os.time() + 60

while os.time() < deadline do
	if readfile(serial):find("1%.%.%d") and
	    readfile(serial):find("test complete", 1, true) then
		break
	end
	os.execute("sleep 0.2")
end

-- ---- the guest's own TAP, passed through ----

local out = readfile(serial):gsub("\r", "")
local guest = {}

for line in (out .. "\n"):gmatch("([^\n]*)\n") do
	if line:match("^ok ") or line:match("^not ok ") or
	    line:match("^# ") then
		guest[#guest + 1] = line
	end
end

-- Two of this file's own, then the guest's, renumbered onto the end. The
-- guest's plan line is dropped: there is one plan, printed here over the
-- total, because meson counts assertions and does not care which side of
-- the serial line made them.
local nassert = 0

for _, line in ipairs(guest) do
	if not line:match("^# ") then
		nassert = nassert + 1
	end
end

print("1.." .. (2 + nassert))

ok(served == 2, "the guest made both connections")
ok(uploaded == UP,
    "the upload arrived in full on the host: " .. uploaded .. " of " .. UP)

for _, line in ipairs(guest) do
	if line:match("^# ") then
		print(line)
	else
		count = count + 1
		local body = line:match("^n?o?t? ?ok %d+ %-? ?(.*)$") or line

		if line:match("^not ok") then
			failed = failed + 1
			print("not ok " .. count .. " - " .. body)
		else
			print("ok " .. count .. " - " .. body)
		end
	end
end

if failed > 0 then
	diag("guest serial transcript:")
	diag(out)
end

cleanup(pid)
os.exit(failed == 0 and 0 or 1)
