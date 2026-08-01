#!/usr/bin/env lua5.4
-- boottest-microvm.lua ELF TEST.lua [--9p] -- boot the bare PVH kernel
-- under qemu's microvm machine with the test payload injected via
-- fw_cfg, and emit the TAP the guest printed on com1.
--
-- the efi harness's counterpart, scripts/boottest.lua, and deliberately
-- separate rather than a branch inside it: there is no firmware, no
-- pflash varstore and no disk here, the payload is the whole guest, and
-- the guest ends by triple-faulting itself (src/platform/microvm/
-- reset.c) rather than through ResetSystem. Little of that harness's
-- body would survive the conditionals.
--
-- --9p serves a temporary directory over virtio-9p, seeded with the
-- hello.txt that test/boot/microvm_p9mount.lua expects. --rng attaches
-- a virtio-rng. Devices are opt-in per test rather than always present
-- because a payload that asks for a device the machine does not have
-- blocks in the driver and only ever surfaces as a harness timeout.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local q = require("arch").quote

local TIMEOUT = os.getenv("TIMEOUT") or "60"
local elf, payload = arg[1], arg[2]
local want9p, wantrng = false, false

for i = 3, #arg do
	if arg[i] == "--9p" then
		want9p = true
	elseif arg[i] == "--rng" then
		wantrng = true
	end
end

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local line = f:read("l")

	f:close()
	return line
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

local function cleanup()
	os.execute("rm -rf " .. q(tmp))
end

-- the 9p share. a directory per invocation, so parallel tests cannot
-- see each other's created.txt.
local p9args = ""

if want9p then
	local share = tmp .. "/share"

	os.execute("mkdir -p " .. q(share))

	local f = assert(io.open(share .. "/hello.txt", "wb"))

	f:write("hello from 9p\n")
	f:close()

	p9args = table.concat({
		"-fsdev local,id=fs0,security_model=none,path=" .. q(share),
		"-device virtio-9p-device,fsdev=fs0,mount_tag=hostshare," ..
		    "bus=virtio-mmio-bus.0",
	}, " ")
end

local rngargs = ""

if wantrng then
	rngargs = "-device virtio-rng-device,bus=virtio-mmio-bus.0"
end

-- ioapic2=off pins virtio-mmio to the documented 8-slot/GSI-5-base
-- layout (qemu's hw/i386/microvm.c): with a second IOAPIC present the
-- machine silently switches to 24 slots at a different irq base, which
-- src/platform/microvm/virtio.c's fixed 8-slot scan would never see.
--
-- no pinning here, unlike the efi harness: that works around a stall
-- inside OVMF during boot device selection, and there is no OVMF.
local cmd = table.concat({
	"timeout", TIMEOUT,
	"qemu-system-x86_64",
	"-M microvm,pit=off,pic=off,rtc=off,ioapic2=off",
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	p9args, rngargs,
	"-nodefaults -no-user-config -no-reboot -nographic",
	"-serial file:" .. q(tmp .. "/serial.log"),
	">/dev/null 2>&1",
}, " ")

local execok, _, code = os.execute(cmd)
local rc = execok and 0 or (code or 1)

local clean = readfile(tmp .. "/serial.log"):gsub("\r", "")

clean = clean:gsub("\27%[[%d;=]*%a", "")

local lines = {}

for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
	lines[#lines + 1] = line
end

local function is_tap_line(line)
	return line:match("^1%.%.") ~= nil or line:match("^ok ") ~= nil or
	    line:match("^not ok ") ~= nil or line:match("^# ") ~= nil
end

local function dump(why)
	print("# " .. why .. "; full serial trace:")
	for _, line in ipairs(lines) do
		print("# " .. line)
	end
end

local sawplan = false

for _, line in ipairs(lines) do
	if is_tap_line(line) then
		print(line)
		if line:match("^1%.%.") then
			sawplan = true
		end
	end
end

if rc ~= 0 then
	dump("qemu exited with " .. rc .. " (124 = timeout)")
	print("not ok - boottest-microvm harness (qemu rc=" .. rc .. ")")
	cleanup()
	os.exit(1)
end

if not sawplan then
	dump("no TAP plan seen")
	print("not ok - boottest-microvm harness (no TAP output)")
	cleanup()
	os.exit(1)
end

cleanup()
os.exit(0)
