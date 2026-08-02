#!/usr/bin/env lua5.4
-- boottest-microvm.lua ELF TEST.lua [--9p] -- boot the bare PVH kernel
-- under qemu's microvm machine with the test payload injected via
-- fw_cfg, and emit the TAP the guest printed on com1.
--
-- TEST.lua of "-" injects nothing, so the guest falls back to the
-- payload embedded in the image (src/platform/microvm/main.c's
-- BOOT_PAYLOAD). That is the only path OpenBSD vmd can take, since its
-- fw_cfg serves a fixed list and cannot be given a host file, and
-- qemu is where it can be tested.
--
-- the efi harness's counterpart, tools/boottest.lua, and deliberately
-- separate rather than a branch inside it: there is no firmware, no
-- pflash varstore and no disk here, the payload is the whole guest, and
-- the guest ends by triple-faulting itself (src/platform/microvm/
-- reset.c) rather than through ResetSystem. Little of that harness's
-- body would survive the conditionals.
--
-- every guest gets a virtio-rng, matching tools/arch.lua's efi
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
local want9p, wantnet, wantecho = false, false, false

for i = 3, #arg do
	if arg[i] == "--9p" then
		want9p = true
	elseif arg[i] == "--net" then
		wantnet = true
	elseif arg[i] == "--netecho" then
		wantnet = true
		wantecho = true
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

-- --netecho adds a peer worth connecting to. slirp hosts no TCP service
-- of its own -- it forwards outward, and a guest dialing its own address
-- does not hairpin -- so until now nothing in the guest could complete a
-- handshake without a host-driven harness on the far side.
--
-- guestfwd solves it without one: qemu runs the command and joins the
-- guest's TCP stream to its stdin and stdout, so `cat` is an echo
-- server, and the whole thing stays an ordinary boot test. Kept behind
-- its own flag rather than folded into --net so that a syntax error
-- here cannot stop every other network test from booting.
local echoargs = ""

if wantecho then
	echoargs = ",guestfwd=tcp:10.0.2.100:7-cmd:cat"
end

if wantnet then
	netargs = table.concat({
		"-netdev user,id=n0" .. echoargs,
		"-device virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2",
	}, " ")
end

-- ioapic2=off and acpi=on together pin where virtio-mmio lands, and
-- both matter. microvm_devices_init (qemu's hw/i386/microvm.c) picks
-- the slot count from the first and the irq base from both: a second
-- ioapic gives 24 transports based at 24, acpi alone gives 8 based at
-- 16, and neither gives 8 based at 5. acpi is microvm's default, so
-- this pins what is already true rather than changing it -- but it is
-- what src/platform/microvm/microvm.h's VIRTIO_MMIO_GSI_BASE assumes,
-- and a default is a poor thing to leave that resting on.
--
-- pit=on is for the clock, not for interrupts: nothing routes irq 0,
-- and src/platform/microvm/tsc.c only latches channel 0 to count the
-- TSC against for 10ms at boot. It is needed because cpuid answers
-- nothing about frequency on an AMD host under qemu -- 0x15 is Intel,
-- 0x16 reads zero, and KVM's 0x40000010 reads zero too -- which left
-- the guest on a 1GHz default against a 4.5GHz TSC, running every
-- timeout in the system 4.5 times fast.
--
-- no pinning of the boot device here, unlike the efi harness: that
-- works around a stall inside OVMF during boot device selection, and
-- there is no OVMF.
local cmd = table.concat({
	"timeout", TIMEOUT,
	"qemu-system-x86_64",
	"-M microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	payload ~= "-" and
	    ("-fw_cfg name=opt/org.luaos.test,file=" .. q(payload)) or "",
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
