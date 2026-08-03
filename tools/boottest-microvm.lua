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
-- creates a file and wants a private directory to do it in. --blk
-- attaches a small seeded raw disk over virtio-blk, and is the one flag
-- whose check continues after the guest has gone: the image is verified
-- on the host afterwards.
--
-- --pci runs the same payload on a q35 with the same devices on PCI
-- instead: virtio-pci behind pcie root ports, which is the shape both
-- systemd-vmspawn and real hardware present. Same tests, other
-- transport -- that is the whole point of it being a flag here rather
-- than a harness of its own.
--
-- --pci0 is the same machine with the devices left on the root bus,
-- where qemu makes them transitional rather than non-transitional: a
-- different set of PCI ids, an IO BAR that a device behind a port does
-- not have, and no bridge to walk. Both shapes occur on one machine --
-- vmspawn puts its rng on bus 0 and its disk behind a port -- so both
-- are worth booting.
--
-- a payload that asks for a device the machine does not have blocks in
-- the driver and surfaces only as a harness timeout, with nothing on
-- the serial line to say which device it was waiting for.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local q = require("arch").quote

local TIMEOUT = os.getenv("TIMEOUT") or "60"
local elf, payload = arg[1], arg[2]
local want9p, wantnet, wantecho, wantblk = false, false, false, false
local wantgefs, wantgefscommit, wantgefsgpt = false, false, false
local wantpci, wantpci0 = false, false

for i = 3, #arg do
	if arg[i] == "--9p" then
		want9p = true
	elseif arg[i] == "--net" then
		wantnet = true
	elseif arg[i] == "--netecho" then
		wantnet = true
		wantecho = true
	elseif arg[i] == "--blk" then
		wantblk = true
	elseif arg[i] == "--gefs" then
		wantgefs = true
	elseif arg[i] == "--gefscommit" then
		-- microvm_gefs.lua commits /guest and the host verifies it
		-- landed; the served/concurrency test does not, so the
		-- durability check is a separate opt-in.
		wantgefs = true
		wantgefscommit = true
	elseif arg[i] == "--gefsgpt" then
		wantgefsgpt = true
	elseif arg[i] == "--pci" then
		wantpci = true
	elseif arg[i] == "--pci0" then
		wantpci = true
		wantpci0 = true
	end
end

-- tools/gefs.lua, reused to seed a --gefs disk and to check it after: the
-- same CLI a person uses to look at a volume, so the fixture is made the
-- way any volume is.
local toolsdir = arg[0]:match("^(.*)/[^/]+$") or "."
local gefscli = toolsdir .. "/gefs.lua"

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

-- one device, named for whichever transport this run uses, and pinned
-- to a bus so nothing rests on a default.
--
-- The slot number means something different on each. On microvm it is
-- an index into the fixed mmio window, which is what fixes the device's
-- gsi. On q35 it is a pcie root port -- and every device gets its own,
-- deliberately: a device behind a root port is non-transitional and
-- MSI-X-driven, and it sits on a bus of its own, which is what makes
-- this exercise the bridge walk in src/platform/microvm/pci.c rather
-- than finding everything on bus 0.
local ports = {}

local function dev(driver, slot)
	if not wantpci then
		return driver .. "-device,bus=virtio-mmio-bus." .. slot
	end

	-- the root bus, where qemu makes a device transitional. There is
	-- no bus to name: pcie.0 is where a -device lands by default.
	if wantpci0 then
		return driver .. "-pci"
	end

	local id = "rp" .. slot

	ports[#ports + 1] = "-device pcie-root-port,id=" .. id ..
	    ",chassis=" .. (slot + 1)
	return driver .. "-pci,bus=" .. id
end

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
		"-device " .. dev("virtio-9p", 0) ..
		    ",fsdev=fs0,mount_tag=hostshare",
	}, " ")
end

-- bus slot 1: the 9p device above takes slot 0 when present, and
-- virtio.c scans a fixed eight slots either way. On PCI the number is a
-- root port instead, and nothing depends on which.
local rngargs = "-device " .. dev("virtio-rng", 1)

-- --blk gives the guest a small raw disk, seeded so that any sector can
-- prove which sector it is: each one begins with its own index, the same
-- trick blocks.bin uses above and for the same reason -- a transport
-- with several requests outstanding has to be shown that replies still
-- match their requests, and identical sectors would hide a swap.
--
-- The image is per invocation and is checked again after the guest
-- exits (see BLK_MARK below), which is the only part of this that a
-- guest-side readback cannot establish: a write that reached the device
-- and came back is not yet a write that reached the file.
local blkargs = ""
local blkimg = tmp .. "/disk.img"

local BLK_SECTORS = 2048		-- 1 MiB
local BLK_SECSZ = 512

-- deliberately unaligned and deliberately spanning a sector boundary
-- (1015 .. 1031 crosses 1024), because that is the case blkfs.lua has
-- to read-modify-write and the one an aligned test would never reach.
local BLK_MARK = "MARKER-FROM-LUAOS"
local BLK_MARK_OFF = 1015

local function blk_sector(i)
	local mark = string.format("sector %04d\n", i)

	return mark .. string.rep(".", BLK_SECSZ - #mark)
end

if wantblk then
	local f = assert(io.open(blkimg, "wb"))

	for i = 0, BLK_SECTORS - 1 do
		f:write(blk_sector(i))
	end
	f:close()

	blkargs = table.concat({
		"-drive if=none,id=d0,format=raw,file=" .. q(blkimg),
		"-device " .. dev("virtio-blk", 3) .. ",drive=d0",
	}, " ")
end

-- --gefs seeds the same virtio-blk disk with a gefs volume instead of
-- marker sectors: the whole disk is one reamed volume, holding files the
-- guest did not write. test/boot/microvm_gefs.lua reads them back and
-- must agree with the constants here.
local GEFS_SIZE = 64 * 1024 * 1024
local GEFS_SMALL = "hello from gefs\n"
local GEFS_BIG = ("gefs"):rep(10000)
local GEFS_GUEST = "written in the guest\n"

local function seedrun(cmd)
	-- the CLI's own progress goes to stdout; keep it out of the TAP stream
	cmd = cmd .. " >/dev/null"
	if os.execute(cmd) ~= true then
		dump("gefs seed failed: " .. cmd)
		print("not ok - boottest-microvm harness (gefs seed failed)")
		cleanup()
		os.exit(1)
	end
end

-- feed a string to `gefs put` through a file, so no content has to
-- survive the shell
local function gefsput(path, content)
	local tf = tmp .. "/put.tmp"
	local f = assert(io.open(tf, "wb"))
	f:write(content)
	f:close()
	seedrun(("lua5.4 %s put %s %s < %s"):format(
	    q(gefscli), q(blkimg), q(path), q(tf)))
end

if wantgefs then
	seedrun(("lua5.4 %s ream %s %d glenda"):format(
	    q(gefscli), q(blkimg), GEFS_SIZE))
	gefsput("/hello", GEFS_SMALL)
	seedrun(("lua5.4 %s mkdir %s /dir"):format(q(gefscli), q(blkimg)))
	gefsput("/dir/big", GEFS_BIG)

	blkargs = table.concat({
		"-drive if=none,id=d0,format=raw,file=" .. q(blkimg),
		"-device virtio-blk-device,drive=d0,bus=virtio-mmio-bus.3",
	}, " ")
end

-- --gefsgpt puts the volume in a GPT partition beside an ESP, the layout
-- a disk booted by firmware has, so the guest must read the table to find
-- where gefs is. The ESP is a bare partition here -- microvm boots the ELF
-- directly and never looks at it; the point is only that a second
-- partition sits after it and the guest locates gefs by name.
local GEFS_ESP_START, GEFS_ESP_SZ = 2048, 90112		-- 44 MiB, sectors
local GEFS_PART_START, GEFS_PART_SZ = 94208, 98304	-- 48 MiB, sectors
local GEFS_PART_OFF = GEFS_PART_START * 512
local GEFS_PART_LEN = GEFS_PART_SZ * 512

local function gefsput_at(path, content, off, len)
	local tf = tmp .. "/put.tmp"
	local f = assert(io.open(tf, "wb"))
	f:write(content)
	f:close()
	seedrun(("lua5.4 %s put %s %s -o %d -l %d < %s"):format(
	    q(gefscli), q(blkimg), q(path), off, len, q(tf)))
end

if wantgefsgpt then
	-- a GPT disk big enough for both partitions plus the backup table
	local secs = GEFS_PART_START + GEFS_PART_SZ + 34
	seedrun(("truncate -s %d %s"):format(secs * 512, q(blkimg)))

	local layout = ("label: gpt\nstart=%d, size=%d, type=uefi, name=\"EFI\"\n" ..
	    "start=%d, size=%d, " ..
	    "type=C91818F9-8025-47AF-89D2-F030D7000C2C, name=\"gefs\"\n"):format(
	    GEFS_ESP_START, GEFS_ESP_SZ, GEFS_PART_START, GEFS_PART_SZ)
	seedrun(("printf %s | sfdisk --no-reread --no-tell-kernel -q %s"):format(
	    q(layout), q(blkimg)))

	-- ream and populate the gefs partition, leaving the table alone
	seedrun(("lua5.4 %s ream %s 0 glenda -o %d -l %d"):format(
	    q(gefscli), q(blkimg), GEFS_PART_OFF, GEFS_PART_LEN))
	gefsput_at("/hello", GEFS_SMALL, GEFS_PART_OFF, GEFS_PART_LEN)
	seedrun(("lua5.4 %s mkdir %s /dir -o %d -l %d"):format(
	    q(gefscli), q(blkimg), GEFS_PART_OFF, GEFS_PART_LEN))
	gefsput_at("/dir/big", GEFS_BIG, GEFS_PART_OFF, GEFS_PART_LEN)

	blkargs = table.concat({
		"-drive if=none,id=d0,format=raw,file=" .. q(blkimg),
		"-device virtio-blk-device,drive=d0,bus=virtio-mmio-bus.3",
	}, " ")
end

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
		"-device " .. dev("virtio-net", 2) .. ",netdev=n0",
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
--
-- the q35 alternative pins nothing, because there is nothing to pin:
-- its firmware numbers the buses and places the BARs, and the guest
-- reads back what it did. What it does bring is a second interrupt
-- controller left running by that firmware, which is intr_init's
-- business (src/platform/microvm/intr.c).
local machine = wantpci and "-M q35" or
    "-M microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on"

local cmd = table.concat({
	"timeout", TIMEOUT,
	"qemu-system-x86_64",
	machine,
	table.concat(ports, " "),
	"-enable-kvm -cpu host -m 256",
	"-kernel " .. q(elf),
	payload ~= "-" and
	    ("-fw_cfg name=opt/org.luaos.test,file=" .. q(payload)) or "",
	p9args, rngargs, netargs, blkargs,
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

-- the durability half of the block test, which has to happen here
-- because it is a question about the host's file rather than about the
-- guest: did the bytes the guest wrote actually land, at the offset it
-- named, without disturbing their neighbours?
--
-- The neighbours are the point. Writing 17 bytes across a sector
-- boundary means blkfs.lua read both sectors, patched the middle and
-- wrote them whole -- so a read-modify-write that got its head or tail
-- slice wrong would still place the marker correctly and would quietly
-- destroy everything around it.
if wantblk then
	local img = readfile(blkimg)
	local got = img:sub(BLK_MARK_OFF + 1, BLK_MARK_OFF + #BLK_MARK)
	local fail

	if got ~= BLK_MARK then
		fail = "marker at " .. BLK_MARK_OFF .. " is " ..
		    string.format("%q", got)
	else
		-- the untouched remainder of each sector the write landed in
		local s1 = blk_sector(1)
		local s2 = blk_sector(2)
		local want = (s1 .. s2):sub(1, BLK_MARK_OFF - BLK_SECSZ) ..
		    BLK_MARK ..
		    (s1 .. s2):sub(BLK_MARK_OFF - BLK_SECSZ + #BLK_MARK + 1)

		if img:sub(BLK_SECSZ + 1, 3 * BLK_SECSZ) ~= want then
			fail = "the bytes around the marker were disturbed"
		end
	end

	if fail then
		dump("block image check failed: " .. fail)
		print("not ok - boottest-microvm harness (blk: " .. fail .. ")")
		cleanup()
		os.exit(1)
	end
	print("# blk: the guest's write survived in the host image")
end

-- the durability half for gefs: reopen the volume from the host and read
-- the file the guest committed. A write that came back inside the guest
-- is not yet one that reached the disk file; only reading it from a fresh
-- open of that file says the commit landed.
if wantgefscommit then
	local out = popen_line(("lua5.4 %s cat %s /guest 2>/dev/null"):format(
	    q(gefscli), q(blkimg)))

	if out ~= GEFS_GUEST:gsub("\n$", "") then
		dump("gefs readback: guest file was " .. tostring(out))
		print("not ok - boottest-microvm harness (gefs: the guest's " ..
		    "commit did not reach the disk)")
		cleanup()
		os.exit(1)
	end
	print("# gefs: the guest's commit survived in the host volume")
end

cleanup()
os.exit(0)
