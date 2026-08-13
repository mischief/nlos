#!/usr/bin/env lua5.4
-- qemu.lua IMG [DISPLAY] -- interactive run.
-- com1 = console on stdio, the 9p wire on ./9p.sock (in cwd, which for
-- `ninja qemu` is the build directory). virtio-net-pci + user-mode
-- networking gives the net task a NIC; guest gets a DHCP lease and can
-- be reached via qemu's usermode NAT (hostfwd if you need inbound).
--
-- with no DISPLAY argument this is -nographic: no window, and the
-- machine's framebuffer goes nowhere you can see. pass one (or set
-- LUAOS_DISPLAY, or run the qemu-gtk target) to open a window as well
-- -- the console stays on stdio either way, which is the arrangement a
-- graphical program run from the dos prompt actually needs: you type in
-- the terminal and watch the screen in the window.
--
-- ---- -snapshot, and why an interactive run wants it too ----
--
-- Without it qemu takes an exclusive write lock on the disk image AND on
-- OVMF_VARS.fd, so `ninja qemu` and `meson test` cannot run at the same
-- time: every boot test fails with a lock error that looks nothing like
-- a lock error. That is a bad trade for persistence nobody was relying
-- on -- ninja rewrites the image on the next build anyway, and the ESP
-- is the build output rather than a place to keep things.
--
-- With -snapshot both files are opened read-only and written through a
-- temporary overlay, so any number of runs coexist, including the test
-- suite (which has always done this -- see tools/boottest.lua).
--
-- The consequence to know: guest writes to the ESP do not survive the
-- run, and neither do EFI variables. Nothing here depends on the
-- latter, because the image boots through the removable-media path
-- (EFI/BOOT/BOOTX64.EFI) rather than an NVRAM boot entry.
--
-- Ports and the wire socket are overridable for the same reason: two
-- interactive runs otherwise collide on the forwards and on 9p.sock,
-- which -snapshot does nothing about.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local img = arg[1]

-- -nographic is more than "no window": it also multiplexes the monitor
-- onto stdio and suppresses the display device wiring. so the two cases
-- differ by one flag each rather than sharing one string.
local graphics = "-nographic"
-- a tablet, and only with a window. It is what the firmware publishes
-- an absolute pointer for, and that is what the machine looks for to
-- decide it has a pointer at all -- so the window system starts here
-- and stays absent from a headless run, where nothing could click it.
local pointer = ""

if arg[2] or os.getenv("LUAOS_DISPLAY") then
	local disp, why = arch.display(arg[2])

	if not disp then
		io.stderr:write(why .. "\n")
		os.exit(1)
	end
	graphics = disp
	pointer = "-device qemu-xhci -device usb-tablet"
end

local function envor(name, fallback)
	local v = os.getenv(name)

	return (v and v ~= "") and v or fallback
end

local p9port = envor("LUAOS_9P_PORT", "7777")
local sshport = envor("LUAOS_SSH_PORT", "2222")
-- the gefs 9P export listens on the styx port 564 inside; map it to an
-- unprivileged host port so `9p -a tcp!localhost!5640 ls /` reaches it
-- without root.
local styxport = envor("LUAOS_STYX_PORT", "5640")
local wiresock = envor("LUAOS_WIRE_SOCK", "9p.sock")

if not io.open("OVMF_VARS.fd", "rb") then
	os.execute("cp " .. q(arch.FW_VARS) .. " OVMF_VARS.fd")
end

local cmd = table.concat({
	arch.QEMU, graphics, pointer, arch.MACHINE, arch.VIDEO, arch.RNG,
	"-snapshot",
	"-netdev user,id=n0,hostfwd=tcp::" .. p9port .. "-:7777" ..
	    ",hostfwd=tcp::" .. sshport .. "-:2222" ..
	    ",hostfwd=tcp::" .. styxport .. "-:564",
	"-device " .. arch.NIC .. ",netdev=n0",
	"-serial mon:stdio",
	arch.wire_args("socket", wiresock),
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=OVMF_VARS.fd",
	"-drive " .. arch.BLK .. ",file=" .. q(img),
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
