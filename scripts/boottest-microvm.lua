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
-- every guest gets a virtio-rng, matching scripts/arch.lua's efi
-- machines. --9p additionally serves a temporary directory over
-- virtio-9p, seeded with the hello.txt that
-- test/boot/microvm_p9mount.lua expects; it is opt-in because that test
-- creates a file and wants a private directory to do it in.
--
-- a payload that asks for a device the machine does not have blocks in
-- the driver and surfaces only as a harness timeout, with nothing on
-- the serial line to say which device it was waiting for.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local q = require("arch").quote

local TIMEOUT = os.getenv("TIMEOUT") or "60"
local elf, payload = arg[1], arg[2]
local want9p, wantnet = false, false

for i = 3, #arg do
	if arg[i] == "--9p" then
		want9p = true
	elseif arg[i] == "--net" then
		wantnet = true
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

	-- blocks.bin exists for test/boot/microvm_p9bench.lua, which reads
	-- it a block at a time to time round trips. Each 4096-byte block
	-- begins with its own index so a read can prove it landed at the
	-- offset it asked for -- the whole question a pipelined transport
	-- has to answer is whether replies still match their requests.
	local b = assert(io.open(share .. "/blocks.bin", "wb"))

	for i = 0, 63 do
		local mark = string.format("block %04d\n", i)

		b:write(mark, string.rep(".", 4096 - #mark))
	end
	b:close()

	p9args = table.concat({
		"-fsdev local,id=fs0,security_model=none,path=" .. q(share),
		"-device virtio-9p-device,fsdev=fs0,mount_tag=hostshare," ..
		    "bus=virtio-mmio-bus.0",
	}, " ")
end

-- bus slot 1: the 9p device above takes slot 0 when present, and
-- virtio.c scans a fixed eight slots either way.
local rngargs = "-device virtio-rng-device,bus=virtio-mmio-bus.1"

-- --net gives the guest qemu's user networking, where slirp answers as
-- the gateway at 10.0.2.2 and leases the guest 10.0.2.15. Enough for an
-- arp exchange to have something on the far side; a bridge would be
-- needed for anything wanting a real segment.
local netargs = ""

if wantnet then
	netargs = table.concat({
		"-netdev user,id=n0",
		"-device virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2",
	}, " ")
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
	p9args, rngargs, netargs,
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
